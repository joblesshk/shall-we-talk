import Foundation

/// 阿里云百炼 Qwen-ASR-Realtime 专用会话。
///
/// 采用 Manual mode:客户端的开始/停止就是唯一断句边界,与 A/B 实验的计时口径一致。
/// 输入直接使用 Recorder 的 16kHz mono Int16 PCM,不经过 OpenAI Realtime 的 24kHz 升采样。
final class QwenRealtimeASRSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let language: String
    private let corpus: String
    private let onPartial: (String) -> Void

    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pendingAudio: [String] = []
    private var acc = ""
    private var finalText: String?
    private var startedAt: Date?
    private var _firstPartialMillis: Int?
    private var ready = false
    private var socketOpen = false
    private var receiving = false
    private var finishRequested = false
    private var finishSent = false
    private var resolved = false
    private var appendedChunks = 0
    private var eventCount = 0
    private var lastEventType = "(none)"
    private var lastError: String?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<String, Error>?

    init(baseURL: URL, apiKey: String, model: String,
         language: String = "zh", corpus: String = "",
         onPartial: @escaping (String) -> Void) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.corpus = corpus
        self.onPartial = onPartial
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    var firstPartialMillis: Int? { _firstPartialMillis }

    var diagnostics: String {
        "socketOpen=\(socketOpen) ready=\(ready) 事件=\(eventCount) 末条=\(lastEventType) " +
        "音频块=\(appendedChunks)" + (lastError.map { " 错误=\($0)" } ?? "")
    }

    private func log(_ message: String) { NSLog("[QWEN-ASR] %@", message) }

    func start() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error("API Key 为空")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error("模型 ID 为空")
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "model" }
        items.append(URLQueryItem(name: "model", value: model))
        components?.queryItems = items
        guard let url = components?.url else { throw error("WebSocket URL 无效") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("ShallWeTalk-macOS/0.2", forHTTPHeaderField: "User-Agent")

        let socket = urlSession.webSocketTask(with: request)
        task = socket
        receiving = true
        startedAt = Date()
        log("connect url=\(url.absoluteString) model=\(model) keyLen=\(apiKey.count)")

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            // 先挂起 continuation 再启动 socket,避免极快的 session.updated 先于等待者到达。
            receiveLoop()
            socket.resume()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.startContinuation != nil else { return }
                self.fail(self.error("连接超时 · \(self.diagnostics)"))
            }
        }
    }

    func feed(_ pcm: Data) {
        guard !resolved, task != nil, !pcm.isEmpty else { return }
        let encoded = pcm.base64EncodedString()
        if ready { appendAudio(encoded) } else { pendingAudio.append(encoded) }
    }

    func finish() async throws -> String {
        if resolved { return finalText ?? acc }
        guard task != nil else { return acc }
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            finishRequested = true
            if ready { beginFinish() }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.finishContinuation != nil else { return }
                self.fail(self.error("收尾超时 · \(self.diagnostics)"))
            }
        }
    }

    func cancel() {
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        let e = CancellationError()
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: e)
        }
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(throwing: e)
        }
        resolved = true
        urlSession?.invalidateAndCancel()
    }

    // MARK: - WebSocket lifecycle

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        socketOpen = true
        log("WS OPENED protocol=\(protocolName ?? "nil")")
        var transcription: [String: Any] = ["language": language]
        let context = corpus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { transcription["corpus"] = ["text": context] }
        let event: [String: Any] = [
            "event_id": eventID(),
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": 16000,
                "input_audio_transcription": transcription,
                "turn_detection": NSNull(),
            ],
        ]
        Task { [weak self] in
            do { try await self?.send(event) }
            catch { self?.fail(error) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(none)"
        log("WS CLOSED code=\(closeCode.rawValue) reason=\(reasonText)")
        if !resolved { fail(error("WebSocket 关闭 code=\(closeCode.rawValue) \(reasonText)")) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError completionError: Error?) {
        guard !resolved else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode
        if let completionError {
            fail(error("连接失败 HTTP=\(code.map(String.init) ?? "none") \(completionError.localizedDescription)"))
        } else if code != 101 {
            fail(error("握手失败 HTTP=\(code.map(String.init) ?? "none")"))
        }
    }

    // MARK: - Protocol events

    private func receiveLoop() {
        guard receiving, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if !self.resolved { self.fail(error) }
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        eventCount += 1
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            log("non-json: \(String(text.prefix(240)))")
            return
        }
        lastEventType = type
        log("recv[\(eventCount)] \(type): \(String(text.prefix(360)))")

        switch type {
        case "session.updated":
            ready = true
            flushPending()
            resolveStart()
            if finishRequested { beginFinish() }
        case "conversation.item.input_audio_transcription.text":
            let confirmed = object["text"] as? String ?? ""
            let stash = object["stash"] as? String ?? ""
            let partial = confirmed + stash
            if !partial.isEmpty {
                if _firstPartialMillis == nil, let startedAt {
                    _firstPartialMillis = Int(Date().timeIntervalSince(startedAt) * 1000)
                }
                acc = partial
                onPartial(partial)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = object["transcript"] as? String {
                finalText = transcript
                acc = transcript
                onPartial(transcript)
            }
        case "conversation.item.input_audio_transcription.failed", "error":
            let detail = (object["error"] as? [String: Any])?["message"] as? String
                ?? String(text.prefix(300))
            fail(error(detail))
        case "session.finished":
            resolveFinal(finalText ?? acc)
        default:
            break
        }
    }

    private func appendAudio(_ base64: String) {
        let event: [String: Any] = [
            "event_id": eventID(),
            "type": "input_audio_buffer.append",
            "audio": base64,
        ]
        guard let string = jsonString(event) else { return }
        task?.send(.string(string)) { [weak self] error in
            if let error { self?.lastError = error.localizedDescription }
        }
        appendedChunks += 1
    }

    private func flushPending() {
        let buffered = pendingAudio
        pendingAudio.removeAll()
        for audio in buffered { appendAudio(audio) }
    }

    private func beginFinish() {
        guard ready, !finishSent else { return }
        finishSent = true
        flushPending()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(["event_id": self.eventID(), "type": "input_audio_buffer.commit"])
                try await self.send(["event_id": self.eventID(), "type": "session.finish"])
            } catch {
                self.fail(error)
            }
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let task, let string = jsonString(object) else { throw error("无法序列化事件") }
        try await task.send(.string(string))
    }

    private func resolveStart() {
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume()
        }
    }

    private func resolveFinal(_ text: String) {
        guard !resolved else { return }
        resolved = true
        receiving = false
        resolveStart()
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(returning: text)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.finishTasksAndInvalidate()
    }

    private func fail(_ failure: Error) {
        guard !resolved else { return }
        lastError = failure.localizedDescription
        log("FAILED: \(failure.localizedDescription)")
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: failure)
        }
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(throwing: failure)
        }
        resolved = true
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    private func eventID() -> String { "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "QwenRealtimeASR", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
