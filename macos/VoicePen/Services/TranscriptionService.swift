import Foundation
import ShallWeTalkCore

/// ASR 抽象层协议本身已移入 ShallWeTalkCore(准入要求见工程规划 §3.2);
/// OpenAICompatibleTranscription 是仅 macOS 使用的实现,留在 App 内。
/// OpenAI 兼容 /audio/transcriptions 端点(SiliconFlow SenseVoice 等国内服务可直接用)
/// Phase 0 用整段上传验证价值;流式 WebSocket 供应商在选型后补充实现
struct OpenAICompatibleTranscription: TranscriptionService {
    let baseURL: URL
    let apiKey: String
    let model: String
    var prompt: String? = nil

    func transcribe(wav: Data) async throws -> String {
        let req = AudioTranscriptionRequest.make(
            baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt, wav: wav)

        let (data, resp) = try await URLSession.shared.data(for: req)
        return try AudioTranscriptionRequest.decode(
            data: data, statusCode: (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }
}

/// ZenMux `/audio/transcriptions`:JSON + Base64 `input_audio`,不是 OpenAI multipart。
struct ZenMuxTranscription: TranscriptionService {
    let baseURL: URL
    let apiKey: String
    let model: String

    func transcribe(wav: Data) async throws -> String {
        let request = try ZenMuxAudioTranscriptionRequest.make(
            baseURL: baseURL, apiKey: apiKey, model: model, wav: wav)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try AudioTranscriptionRequest.decode(
            data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
}
