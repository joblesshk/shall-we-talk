import Foundation

#if canImport(CoreML)
import CoreML

/// Silero VAD 的 CoreML 推理封装。只负责「一块音频 → 语音概率」,判定逻辑在
/// `VoiceActivityPolicy` 里。
///
/// **为什么不直接依赖 FluidAudio**(它也提供 Silero VAD 的 CoreML 封装):
/// 那个包是单一 library target,为了 VAD 会一并链接 ASR、说话人分离、TTS,
/// 以及一个预编译的 Rust 二进制框架(NemoTextProcessing),且要求 iOS 17+。
/// 这里只取模型本身(MIT,约 1MB),推理代码不到百行,不引入任何二进制依赖,
/// 且模型 specificationVersion 6 对应 iOS 15+,不必抬高部署目标。
///
/// 模型:`silero-vad-unified-256ms-v6.2.1`(Silero v6.2.1,MIT)。
/// 每次推理消费 4096 个新样本(16kHz 下 256ms)加 64 个上下文样本,
/// 并携带一对 LSTM 状态在块之间传递。
@available(iOS 15.0, macOS 12.0, *)
public final class SileroVAD {
    /// 每次推理消费的新样本数(16kHz × 256ms)。
    public static let hopSamples = 4096
    /// 模型输入总长 = 新样本 + 上一块尾部保留的上下文。
    public static let inputSamples = 4160
    private static let contextSamples = inputSamples - hopSamples   // 64
    public static let sampleRate: Double = 16_000

    private let model: MLModel
    private var hiddenState: MLMultiArray
    private var cellState: MLMultiArray
    /// 上一块末尾的 64 个样本,作为下一块的前置上下文。
    private var context = [Float](repeating: 0, count: contextSamples)

    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        hiddenState = try Self.zeros()
        cellState = try Self.zeros()
    }

    private static func zeros() throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 128], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: 128)
        pointer.update(repeating: 0, count: 128)
        return array
    }

    /// 回到起录初态:清空 LSTM 状态与上下文。每次开始新录音前调用,
    /// 否则上一次录音的尾部会影响这一次的前几块判定。
    public func reset() throws {
        hiddenState = try Self.zeros()
        cellState = try Self.zeros()
        context = [Float](repeating: 0, count: Self.contextSamples)
    }

    /// 输入正好 `hopSamples` 个 16kHz 单声道 Float32 样本,返回该块的语音概率(0...1)。
    public func probability(forHop hop: [Float]) throws -> Float {
        precondition(hop.count == Self.hopSamples,
                     "Silero VAD 每块必须是 \(Self.hopSamples) 个样本,收到 \(hop.count)")
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.inputSamples)], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: Self.inputSamples)
        context.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
        hop.withUnsafeBufferPointer {
            (pointer + Self.contextSamples).update(from: $0.baseAddress!, count: $0.count)
        }
        context = Array(hop.suffix(Self.contextSamples))

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: input),
            "hidden_state": MLFeatureValue(multiArray: hiddenState),
            "cell_state": MLFeatureValue(multiArray: cellState),
        ])
        let output = try model.prediction(from: provider)
        guard let vad = output.featureValue(for: "vad_output")?.multiArrayValue,
              let hidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let cell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
            throw NSError(domain: "SileroVAD", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "模型输出缺少预期字段"])
        }
        hiddenState = hidden
        cellState = cell
        return vad[0].floatValue
    }
}

/// 把变长的 16kHz Int16 音频块攒成 VAD 需要的定长 Float32 块。
///
/// 必要性:`Recorder` 的 tap 按设备原生采样率取 4096 帧,重采样到 16kHz 后每块
/// 约 1365 个样本且不固定;而模型要求每次正好 4096 个。这一层只做缓冲和格式转换,
/// 不含判定逻辑,因此同样可以脱离 CoreML 单测。
public struct HopAccumulator: Sendable {
    private var buffer: [Float] = []
    private let hopSamples: Int

    public init(hopSamples: Int = 4096) {
        self.hopSamples = hopSamples
        buffer.reserveCapacity(hopSamples * 2)
    }

    /// 追加一段 Int16 小端 PCM,返回本次凑满的所有整块。
    public mutating func append(int16PCM data: Data) -> [[Float]] {
        buffer.reserveCapacity(buffer.count + data.count / 2)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples { buffer.append(Float(sample) / 32768) }
        }
        return drainHops()
    }

    public mutating func append(samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        return drainHops()
    }

    private mutating func drainHops() -> [[Float]] {
        var hops: [[Float]] = []
        while buffer.count >= hopSamples {
            hops.append(Array(buffer.prefix(hopSamples)))
            buffer.removeFirst(hopSamples)
        }
        return hops
    }

    /// 收尾:不足一块的尾部补零凑成一块;没有残留时返回 nil。
    public mutating func flush() -> [Float]? {
        guard !buffer.isEmpty else { return nil }
        var tail = buffer
        tail.append(contentsOf: [Float](repeating: 0, count: hopSamples - tail.count))
        buffer.removeAll(keepingCapacity: true)
        return tail
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
#endif
