import Foundation

/// ASR 抽象层:后续新增流式/其他供应商时实现本协议即可。
public protocol TranscriptionService {
    func transcribe(wav: Data) async throws -> String
}
