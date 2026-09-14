import Foundation

#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech

/// 端侧整段离线转写(Apple SpeechAnalyzer)。
///
/// 定位是云端 ASR 的**配角**：用于云端主听写彻底失败后的离线兜底，以及会议录音的
/// 端侧分块字幕。任何一次失败都必须静默降级，不影响云端主链路。
///
/// 刻意不做成可配置项(2026-08-14 用户决定):模型固定用系统内置的 `SpeechTranscriber`,
/// locale 固定 zh-CN,不进设置页。可切换的只有云端模型。
///
/// 用 `.transcription` 预设(只出最终结果,不出 volatile 中间态)——这里要的是整段稿,
/// 中间态由云端流式负责。
@available(iOS 26.0, macOS 26.0, *)
public struct OnDeviceTranscriber: TranscriptionService {
    /// 固定中文。2026-08-14 在 237 条真实语料上实测:固定 zh-CN 时中文片段与云端字符差异率
    /// 11.0%,英文为主的片段 28.3%。语料里英文为主的只占 5%,固定中文是当前语料下的最优解。
    public static let locale = Locale(identifier: "zh-CN")

    public init() {}

    /// 本机是否具备可用的端侧转写能力。`false` 时所有调用方直接跳过,不报错。
    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    /// 确认语言资产已安装,必要时触发下载。
    ///
    /// 首次使用要下载模型,不能挂在录音路径上阻塞用户;调用方应在空闲时机 fire-and-forget 调用。
    /// 失败不抛错——资产没装好只意味着端侧功能这次不可用。
    public static func prepareAssets() async {
        guard isSupported else { return }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier == supported.identifier }) else { return }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        try? await request.downloadAndInstall()
    }

    /// 语言资产是否已就绪。未就绪时 `transcribe` 会失败,调用方据此决定要不要费这一趟。
    public static var isReady: Bool {
        get async {
            guard isSupported else { return false }
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
            return await SpeechTranscriber.installedLocales.contains { $0.identifier == supported.identifier }
        }
    }

    public func transcribe(wav: Data) async throws -> String {
        guard Self.isSupported else { throw Self.err("本机不支持端侧语音识别") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
            throw Self.err("端侧语音识别不支持 \(Self.locale.identifier)")
        }
        // SpeechAnalyzer 的整段入口收 AVAudioFile,先把内存里的 WAV 落到临时文件。
        // 录音本身也要落盘,这点额外 I/O(约 200KB)相对一次网络往返可以忽略。
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ondevice-\(UUID().uuidString).wav")
        try wav.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () -> String in
            var pieces: [String] = []
            for try await result in module.results {
                pieces.append(String(result.text.characters))
            }
            return pieces.joined()
        }
        do {
            let file = try AVAudioFile(forReading: tempURL)
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "OnDeviceTranscriber", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
