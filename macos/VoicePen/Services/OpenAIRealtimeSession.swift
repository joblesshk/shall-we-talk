import Foundation

/// OpenAI Realtime 转写会话(gpt-realtime-whisper)——全流式,带 **WebSocket 握手级诊断**。
/// 日志前缀 `[RT]`(Xcode 控制台 / Console.app 过滤)。
///
/// 用 delegate 版 URLSession,捕获默认 API 拿不到的握手细节:
///   didOpenWithProtocol(连接成功)/ didCloseWith(关闭码+原因,OpenAI 常写明拒绝理由)/
///   didCompleteWithError(底层错误 + 握手 HTTP 状态码)。
/// "Socket is not connected" = 握手失败,真正原因看 WS CLOSED / didComplete 那两行。
final class OpenAIRealtimeSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let onPartial: (String) -> Void
    // Delegate callbacks, audio capture and finish/cancel use different queues.
    // Never hold this lock across an await.
    private let stateLock = NSRecursiveLock()
    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return try body()
    }

    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?
    private var acc = ""
    private var finalText: String?
    private var startedAt: Date?
    private var _firstPartialMillis: Int?
    private var finishWaiters: [CheckedContinuation<String, Error>] = []
    private var finishError: Error?
    private var finishTimer: Task<Void, Never>?
    private var finished = false
    private var receiving = false

    // 就绪门控
    private var ready = false
    private var pendingAudio: [String] = []
    private var appendedChunks = 0
    private var committed = false

    // 诊断
    private var storedLastError: String?
    private var storedEventCount = 0
    private var storedLastEventType = "(none)"
    private(set) var lastError: String? {
        get { withState { storedLastError } }
        set { withState { storedLastError = newValue } }
    }
    private(set) var eventCount: Int {
        get { withState { storedEventCount } }
        set { withState { storedEventCount = newValue } }
    }
    private(set) var lastEventType: String {
        get { withState { storedLastEventType } }
        set { withState { storedLastEventType = newValue } }
    }
    private var socketOpen = false
    private var handshakeInfo = "(未完成)"

    init(apiKey: String, model: String, language: String? = nil, sampleRate: Int = 24000,
         onPartial: @escaping (String) -> Void) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.onPartial = onPartial
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    var firstPartialMillis: Int? { withState { _firstPartialMillis } }

    var diagnostics: String {
        withState {
        "无结果 · socketOpen=\(socketOpen) 握手=\(handshakeInfo) 事件=\(eventCount) 末条=\(lastEventType) " +
        "音频块=\(appendedChunks) 已提交=\(committed)" + (lastError != nil ? " 错误=\(lastError!)" : "")
        }
    }

    private func log(_ m: String) { NSLog("[RT] %@", m) }

    // MARK: - 生命周期

    func start() async throws {
        var comps = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        comps.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = comps.url else { throw err("bad url") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // 注意:不要发 OpenAI-Beta: realtime=v1 —— 那会切到已停用的 Beta 协议
        // (实测报 code=4000 beta_api_shape_disabled)。默认即 GA /v1/realtime 正式版。
        try withState {
            guard !finished else { throw CancellationError() }
            guard task == nil else { throw err("session already started") }
            let t = urlSession.webSocketTask(with: req)
            task = t
            receiving = true
            receiveLoop()
            t.resume()
            startedAt = Date()
        }
        log("connect url=\(url.absoluteString) model=\(model) rate=\(sampleRate) keyLen=\(apiKey.count)")

        var transcription: [String: Any] = ["model": model]
        if let language { transcription["language"] = language }
        let cfg: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        log("send session.update: \(jsonString(cfg) ?? "")")
        do {
            try await send(cfg)
        } catch {
            log("session.update send FAILED: \(error.localizedDescription) — WS 握手多半没成功,看下面 WS CLOSED / didComplete")
            lastError = "发送失败(握手未成功):\(error.localizedDescription)"
            // 不抛出,让 finish() 走超时并带出握手诊断
        }
    }

    func feed(_ pcm: Data) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !finished, task != nil else { return }
        // 录音是 16k mono Int16,OpenAI Realtime 要求 ≥24k → 升采样到 24k(线性插值,ASR 足够)
        let out = Self.upsample16to24(pcm)
        let b64 = out.base64EncodedString()
        if ready { appendAudio(b64) } else { pendingAudio.append(b64) }
    }

    /// 16k mono Int16 → 24k mono Int16(线性插值,比例 3:2)。
    static func upsample16to24(_ data: Data) -> Data {
        let inCount = data.count / MemoryLayout<Int16>.size
        guard inCount > 1 else { return data }
        let input = data.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        let outCount = inCount * 3 / 2
        var output = [Int16](repeating: 0, count: outCount)
        for j in 0..<outCount {
            let pos = Double(j) * 2.0 / 3.0
            let i0 = Int(pos)
            let i1 = min(i0 + 1, inCount - 1)
            let frac = pos - Double(i0)
            let a = Double(input[min(i0, inCount - 1)])
            let b = Double(input[i1])
            output[j] = Int16(max(-32768, min(32767, a + (b - a) * frac)))
        }
        return output.withUnsafeBytes { Data($0) }
    }

    private func appendAudio(_ b64: String) {
        let msg: [String: Any] = ["type": "input_audio_buffer.append", "audio": b64]
        guard let s = jsonString(msg) else { return }
        task?.send(.string(s)) { [weak self] e in
            if let e { self?.log("append send err: \(e.localizedDescription)") }
        }
        appendedChunks += 1
    }

    private func flushPending() {
        guard !pendingAudio.isEmpty else { return }
        log("flush \(pendingAudio.count) buffered audio chunks")
        let buf = pendingAudio; pendingAudio.removeAll()
        for b in buf { appendAudio(b) }
    }

    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                withState {
                    if finished {
                        if let finishError { cont.resume(throwing: finishError) }
                        else { cont.resume(returning: finalText ?? acc) }
                        return
                    }
                    guard task != nil else { cont.resume(returning: acc); return }
                    finishWaiters.append(cont)
                    guard !committed else { return }
                    committed = true
                    // Budget starts before commit transmission, not after it completes.
                    finishTimer = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                        catch { return }
                        guard let self else { return }
                        self.withState { self.resolve(self.finalText ?? self.acc) }
                    }
                    ready = true
                    flushPending()
                    if let message = jsonString(["type": "input_audio_buffer.commit"]) {
                        task?.send(.string(message)) { _ in }
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        resolve(finalText ?? acc)
    }

    // MARK: - URLSessionWebSocketDelegate(握手级诊断)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        stateLock.lock(); defer { stateLock.unlock() }
        socketOpen = true
        handshakeInfo = "已打开(protocol=\(proto ?? "nil"))"
        log("WS OPENED protocol=\(proto ?? "nil")")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(无 reason)"
        handshakeInfo = "已关闭 code=\(closeCode.rawValue) reason=\(r)"
        if lastError == nil { lastError = handshakeInfo }
        log("WS CLOSED code=\(closeCode.rawValue) reason=\(r)")
        resolve(finalText ?? acc)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock(); defer { stateLock.unlock() }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let statusStr = status.map { "HTTP \($0)" } ?? "无 HTTP 响应"
        let errStr = error.map { "\(($0 as NSError).domain)#\(($0 as NSError).code) \($0.localizedDescription)" } ?? "nil"
        let info = "didComplete \(statusStr) err=\(errStr)"
        if socketOpen == false { handshakeInfo = "握手失败 · \(statusStr)" }
        if lastError == nil { lastError = info }
        log("WS \(info)")
        resolve(finalText ?? acc)
    }

    // MARK: - 收发

    private func send(_ obj: [String: Any]) async throws {
        guard let task = withState({ self.task }), let s = jsonString(obj) else { return }
        try await task.send(.string(s))
    }

    private func receiveLoop() {
        guard receiving, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            guard !self.finished else { return }
            switch result {
            case .failure(let e):
                if self.lastError == nil { self.lastError = "recv: \(e.localizedDescription)" }
                self.log("recv error: \(e.localizedDescription)")
                self.resolve(self.finalText ?? self.acc)
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ s: String) {
        eventCount += 1
        guard let d = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let type = obj["type"] as? String else {
            log("recv[\(eventCount)] non-json: \(String(s.prefix(200)))")
            return
        }
        lastEventType = type
        log("recv[\(eventCount)] \(type): \(String(s.prefix(400)))")

        switch type {
        case "session.created", "session.updated",
             "transcription_session.created", "transcription_session.updated":
            if !ready { ready = true; log("session ready → flush audio"); flushPending() }
        case "conversation.item.input_audio_transcription.delta", "transcription.text.delta":
            if let delta = (obj["delta"] as? String) ?? (obj["text"] as? String), !delta.isEmpty {
                if _firstPartialMillis == nil, let s0 = startedAt {
                    _firstPartialMillis = Int(Date().timeIntervalSince(s0) * 1000)
                }
                acc += delta
                onPartial(acc)
            }
        case "conversation.item.input_audio_transcription.completed", "transcription.text.done":
            if let t = (obj["transcript"] as? String) ?? (obj["text"] as? String) {
                finalText = t
                log("COMPLETED transcript(\(t.count)字)")
                resolve(t)
            }
        case "error", "input_audio_buffer.error":
            let m = (obj["error"] as? [String: Any])?["message"] as? String ?? String(s.prefix(300))
            lastError = m
            log("SERVER ERROR: \(m)")
            resolveError(err(m))
        default:
            break
        }
    }

    private func resolve(_ text: String) {
        guard !finished else { return }
        finished = true
        finalText = text
        finishTimer?.cancel(); finishTimer = nil
        receiving = false
        task?.cancel(with: .normalClosure, reason: nil)
        let waiters = finishWaiters; finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: text) }
        urlSession?.invalidateAndCancel()
    }
    private func resolveError(_ e: Error) {
        guard !finished else { return }
        finished = true
        finishError = e
        finishTimer?.cancel(); finishTimer = nil
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        let waiters = finishWaiters; finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: e) }
        urlSession?.invalidateAndCancel()
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private func err(_ m: String) -> NSError {
        NSError(domain: "OpenAIRealtime", code: -1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
