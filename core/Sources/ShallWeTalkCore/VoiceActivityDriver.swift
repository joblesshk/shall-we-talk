import Foundation

#if canImport(CoreML)
import CoreML

/// 把录音链路的 PCM 流接到 Silero VAD 上,输出「现在算不算在说话」。
///
/// 三条硬约束:
/// 1. **绝不阻塞音频线程**。`feed` 只做一次内存拷贝就返回,推理在自己的串行队列上跑
///    (实测每 256ms 块 0.16ms,但音频线程是实时线程,不该在上面做任何模型推理)。
/// 2. **模型不可用时必须能降级**。`isAvailable` 为 false 时调用方要退回原来的
///    RMS 阈值判定——否则 `lastVoiceAt` 永不更新,静音会一路累积到自动停录,
///    等于录一次废一次。
/// 3. **判定逻辑不在这里**。迟滞与最短语音时长在 `VoiceActivityPolicy`(纯函数、可单测),
///    这里只做搬运。
public final class VoiceActivityDriver: @unchecked Sendable {
    /// 每次判定结果回调(在内部串行队列上触发,调用方自行切回所需上下文)。
    public var onSpeechState: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "org.example.voicepen.vad", qos: .userInitiated)
    private let vad: SileroVAD?
    private var accumulator = HopAccumulator(hopSamples: SileroVAD.hopSamples)
    private var policy = VoiceActivityPolicy()

    /// 模型是否加载成功。false 时 `feed` 不做任何事,调用方必须走 RMS 兜底。
    public var isAvailable: Bool { vad != nil }

    /// 随包分发的模型位置。取不到时返回 nil,构造函数据此进入不可用状态。
    public static var bundledModelURL: URL? {
        Bundle.module.url(forResource: "silero-vad-unified-256ms-v6.2.1",
                          withExtension: "mlmodelc")
    }

    public init(modelURL: URL? = VoiceActivityDriver.bundledModelURL,
                config: VoiceActivityPolicy.Config = .init()) {
        policy = VoiceActivityPolicy(config: config)
        guard #available(iOS 15.0, macOS 12.0, *), let modelURL else {
            vad = nil
            CoreDiagLog.log("vad", "VAD 模型不可用,退回 RMS 阈值判定")
            return
        }
        do {
            vad = try SileroVAD(modelURL: modelURL)
        } catch {
            vad = nil
            CoreDiagLog.log("vad", "VAD 模型加载失败,退回 RMS 阈值判定: \(error.localizedDescription)")
        }
    }

    /// 起录前复位。必须调用:LSTM 状态与候选计数会跨录音残留。
    public func reset() {
        queue.async { [self] in
            accumulator.reset()
            policy.reset()
            if #available(iOS 15.0, macOS 12.0, *) { try? vad?.reset() }
        }
    }

    /// 喂入一段 16kHz 单声道 Int16 PCM。可在音频线程调用。
    public func feed(_ pcm: Data) {
        guard vad != nil else { return }
        queue.async { [self] in
            guard #available(iOS 15.0, macOS 12.0, *), let vad else { return }
            for hop in accumulator.append(int16PCM: pcm) {
                guard let probability = try? vad.probability(forHop: hop) else { continue }
                let step = policy.step(probability: probability)
                onSpeechState?(step.isSpeech)
            }
        }
    }
}
#endif
