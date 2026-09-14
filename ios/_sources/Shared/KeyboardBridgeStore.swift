import Foundation

enum KeyboardBridgePhase: String, Codable {
    case idle
    case opening
    case recording
    case processing
    case ready
    case inserted
    case error
}

/// `.processing` 内部的真实阶段；用于让 App/键盘区分“等待 ASR 终稿”与“LLM 整理”。
enum DictationProcessingStage: String, Codable {
    case recognizing
    case cleaning
}

enum KeyboardBridgeRequestAction: String {
    case record
    case stop
    /// 语音二次修改(修改模式,P1)。与 `.record` 共用整套录音状态机,唯一区别是
    /// App 侧要拿 `editBaseText` 当作修改目标,不当成一次新的口述。
    case edit
}

struct KeyboardBridgeSnapshot: Codable {
    var phase: KeyboardBridgePhase
    var liveText: String
    var cachedText: String
    var finalText: String
    var insertedText: String
    var errorText: String
    var updatedAt: TimeInterval
    var appHeartbeatAt: TimeInterval
    var requestID: String
    var handledRequestID: String
    /// 产生当前待插入结果的键盘请求 ID。Optional 兼容升级前的旧快照；旧快照没有
    /// 归属信息时不得自动插入，避免把 App 内独立口述当成键盘结果。
    var resultRequestID: String? = nil
    /// true = App 明确判断"此刻无法在后台发起新录音"(iOS 限制,非偶发错误)。
    /// 键盘据此重新显示跳转 Link,而不是停留在一条死的失败文案上。
    var needsForeground: Bool = false
    /// 键盘发起本次请求的时刻(键盘时钟即系统时钟,与 App 同源)。
    /// App 接单时用它算「点击→App 处理」延迟,写 [APP][perf] 诊断,定位起录卡顿。
    var requestSentAt: TimeInterval = 0
    /// App 的录音引擎/音频会话是否仍在热态,可接受键盘后台直接起录。
    /// Optional 用于兼容升级前已写入 App Group 的旧快照;缺失时按 false 处理。
    var canStartRecordingInBackground: Bool? = nil
    /// Optional 用于兼容升级前已落盘的桥快照。
    var processingStage: DictationProcessingStage? = nil
    /// 本次请求发起时,键盘所处的宿主输入框语义(见 `HostFieldKind`)。
    /// Optional 兼容旧快照:缺失时主 App 按 `.general` 处理,即改造前的行为。
    var fieldKind: HostFieldKind? = nil
    /// `.edit` 请求携带的修改原文；录音期间不修改宿主文档。
    /// 只在 requestID 前缀为 `edit:` 时有意义;`.record` 请求不写这个字段。
    var editBaseText: String? = nil
    var editTarget: KeyboardEditTarget? = nil
    /// 当前响度包络(0...1),驱动键盘录音键上的波形——取代此前与输入无关的循环动画。
    /// 只在 `phase == .recording` 时有意义;Optional 兼容升级前已落盘的旧快照。
    var audioLevel: Float? = nil
    var returnTarget: HostReturnTarget? = nil
    var returnedDocumentID: UUID? = nil
}

/// Shall We Talk 键盘当前所在的宿主输入文档。
///
/// Action Button 开始录音时锁定这个 ID，结束时只有同一输入文档
/// 仍在使用 Shall We Talk 键盘才允许自动插入，避免切换 App/输入框后误写。
struct KeyboardInsertionTarget: Codable, Equatable {
    let documentID: UUID
}

/// 修改目标独立于冷启动返回目标；旧快照没有该字段时不执行自动删除。
struct KeyboardEditTarget: Codable, Equatable {
    let documentID: UUID
    let hostPID: Int?
    let before: String
    let after: String?

    func matches(documentID: UUID, hostPID: Int?, before: String?, after: String?) -> Bool {
        self.documentID == documentID && self.hostPID == hostPID
            && self.before == before && self.after == after
    }
}

/// 一次代理采样；hasText 才是输入控件是否为空的依据，上下文允许为 nil。
struct KeyboardEditContext {
    var documentID: UUID
    var hostPID: Int?
    var before: String?
    var after: String?
    var hasText: Bool
}

enum KeyboardEditReplacement {
    enum Outcome: Equatable {
        case inserted(deletions: Int)
        case failed(reason: String, deletions: Int)
    }

    /// 同步执行，外层交付锁防止结果重入。每次删除和最终插入前均检查目标身份。
    static func perform(target: KeyboardEditTarget, baseText: String, replacement: String,
                        read: () -> KeyboardEditContext,
                        deleteBackward: () -> Void, insert: (String) -> Void) -> Outcome {
        let initial = read()
        guard !replacement.isEmpty, !baseText.isEmpty, target.before.hasSuffix(baseText),
              target.matches(documentID: initial.documentID, hostPID: initial.hostPID,
                             before: initial.before, after: initial.after),
              initial.after?.isEmpty != false else {
            return .failed(reason: "输入框或原文已变化，未执行替换", deletions: 0)
        }
        let preservedPrefix = String(target.before.dropLast(baseText.count))
        var deletions = 0
        var previousBefore: String?
        let limit = min(4096, max(256, target.before.count * 2 + 32))
        while true {
            let current = read()
            guard current.documentID == target.documentID, current.hostPID == target.hostPID,
                  current.after?.isEmpty != false else {
                return .failed(reason: "输入框已切换，停止替换", deletions: deletions)
            }
            // 删除到目标片段之前的前缀就停止，不能清空整框；整框原本只有目标时允许 nil。
            if current.before == preservedPrefix || (preservedPrefix.isEmpty && !current.hasText) {
                insert(replacement)
                return .inserted(deletions: deletions)
            }
            guard deletions < limit, let before = current.before, !before.isEmpty,
                  before != previousBefore, before.hasPrefix(preservedPrefix),
                  before.count > preservedPrefix.count, current.after?.isEmpty != false else {
                return .failed(reason: "宿主未确认删除进度，停止替换", deletions: deletions)
            }
            previousBefore = before
            deleteBackward()
            deletions += 1
        }
    }
}

private struct KeyboardPresence: Codable {
    let sessionID: String
    let target: KeyboardInsertionTarget
    let updatedAt: TimeInterval
}

private struct ActionKeyboardDelivery: Codable {
    let requestID: String
    let target: KeyboardInsertionTarget
    let createdAt: TimeInterval
}

enum KeyboardBridgeStore {
    private static let snapshotKey = "keyboardBridgeSnapshot"
    private static let keyboardPresenceKey = "keyboardBridge.keyboardPresence.v1"
    private static let actionKeyboardDeliveryKey = "keyboardBridge.actionDelivery.v1"
    // 免费账号 App Group 不可用时为 nil → 桥整体 no-op,键盘退回 voicepen://record 拉起主 App
    private static var suite: UserDefaults? { AppGroup.suite }
    static let awakeTTL: TimeInterval = 12
    static let directRequestTTL: TimeInterval = 2
    /// 键盘每 0.5 秒刷新一次在线心跳；2 秒窗口可容忍短暂调度抖动，
    /// 又不会把已经收起/切换的键盘当成当前输入目标。
    static let keyboardPresenceTTL: TimeInterval = 2
    /// Action 结果是「就在当前输入框立即上屏」，不是可以几分钟后恢复的队列。
    /// 8 秒足够覆盖键盘扩展短暂被调度的情况，又不会突然插入旧口述。
    static let actionKeyboardDeliveryTTL: TimeInterval = 8

    static var emptySnapshot: KeyboardBridgeSnapshot {
        KeyboardBridgeSnapshot(
            phase: .idle,
            liveText: "",
            cachedText: "",
            finalText: "",
            insertedText: "",
            errorText: "",
            updatedAt: Date().timeIntervalSince1970,
            appHeartbeatAt: 0,
            requestID: "",
            handledRequestID: ""
        )
    }

    static func snapshot() -> KeyboardBridgeSnapshot {
        guard let data = suite?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(KeyboardBridgeSnapshot.self, from: data) else {
            return emptySnapshot
        }
        return snapshot
    }

    static func publish(_ update: (inout KeyboardBridgeSnapshot) -> Void) {
        var snapshot = snapshot()
        update(&snapshot)
        snapshot.updatedAt = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(snapshot) {
            suite?.set(data, forKey: snapshotKey)
        }
    }

    @discardableResult
    static func requestRecording(fieldKind: HostFieldKind = .general, returnTarget: HostReturnTarget? = nil) -> String {
        let id = "\(KeyboardBridgeRequestAction.record.rawValue):\(UUID().uuidString)"
        // 新请求开始即丢弃上一次未消费结果；每次键盘口述只接收自己的新结果。
        PendingTextStore.clear()
        publish { snapshot in
            snapshot.phase = .opening
            snapshot.returnedDocumentID = nil
            snapshot.requestID = id
            // 输入框语义随请求走:同一个键盘实例可能在两次口述之间被切到别的输入框,
            // 因此不能缓存,必须每次发起请求时重新读取。
            snapshot.fieldKind = fieldKind
            snapshot.returnTarget = returnTarget
            snapshot.liveText = ""
            snapshot.cachedText = ""
            snapshot.finalText = ""
            snapshot.insertedText = ""
            snapshot.errorText = ""
            snapshot.resultRequestID = nil
            snapshot.requestSentAt = Date().timeIntervalSince1970
            // 上一轮若是修改请求且没走到底(比如中途出错),editBaseText 可能还留着——
            // 这是一次普通口述,必须清掉,否则交付时会被误当成修改结果去做替换。
            snapshot.editBaseText = nil; snapshot.editTarget = nil
        }
        // 唤醒 App 立即处理,免等下一个 0.5s 轮询(削起录前的≈0.5s 等待)
        DarwinBridge.post(DarwinBridge.cmdKick)
        return id
    }

    /// 修改模式：键盘只读保存宿主上下文与原文,
    /// 这里只是告诉 App "把接下来这段录音当修改要求处理,原文是 baseText"。
    /// 复用 `.record` 的整套请求/轮询/后台起录机制,只是 requestID 前缀和 payload 不同。
    @discardableResult
    static func requestEditRecording(baseText: String, fieldKind: HostFieldKind = .general, target: KeyboardEditTarget? = nil) -> String {
        let id = "\(KeyboardBridgeRequestAction.edit.rawValue):\(UUID().uuidString)"
        PendingTextStore.clear()
        publish { snapshot in
            snapshot.phase = .opening
            snapshot.returnedDocumentID = nil
            snapshot.requestID = id
            snapshot.returnTarget = nil
            snapshot.fieldKind = fieldKind
            snapshot.editBaseText = baseText
            snapshot.editTarget = target
            snapshot.liveText = ""
            snapshot.cachedText = ""
            snapshot.finalText = ""
            snapshot.insertedText = ""
            snapshot.errorText = ""
            snapshot.resultRequestID = nil
            snapshot.requestSentAt = Date().timeIntervalSince1970
        }
        DarwinBridge.post(DarwinBridge.cmdKick)
        return id
    }

    @discardableResult
    static func requestStopRecording() -> String {
        let id = "\(KeyboardBridgeRequestAction.stop.rawValue):\(UUID().uuidString)"
        publish { snapshot in
            snapshot.requestID = id
            snapshot.requestSentAt = Date().timeIntervalSince1970
        }
        DarwinBridge.post(DarwinBridge.cmdKick)
        return id
    }

    static func pendingRequest(after handledRequestID: String?) -> String? {
        let snapshot = snapshot()
        guard !snapshot.requestID.isEmpty,
              snapshot.requestID != handledRequestID,
              snapshot.requestID != snapshot.handledRequestID else {
            return nil
        }
        return snapshot.requestID
    }

    static func pendingRequestAction(after handledRequestID: String?) -> (id: String, action: KeyboardBridgeRequestAction)? {
        guard let id = pendingRequest(after: handledRequestID) else { return nil }
        if id.hasPrefix("\(KeyboardBridgeRequestAction.stop.rawValue):") {
            return (id, .stop)
        }
        if id.hasPrefix("\(KeyboardBridgeRequestAction.edit.rawValue):") {
            return (id, .edit)
        }
        return (id, .record)
    }

    static func markRequestHandled(_ requestID: String) {
        publish { snapshot in
            snapshot.handledRequestID = requestID
        }
    }

    static func publishAppState(phase: KeyboardBridgePhase,
                                processingStage: DictationProcessingStage? = nil,
                                liveText: String,
                                cachedText: String,
                                finalText: String,
                                errorText: String = "",
                                needsForeground: Bool = false,
                                canStartRecordingInBackground: Bool = false,
                                audioLevel: Float? = nil) {
        publish { snapshot in
            let alreadyInserted = phase == .ready &&
                suite?.string(forKey: "keyboardBridge.insertedRequestID") == snapshot.handledRequestID
            let handedOff = phase == .ready &&
                suite?.string(forKey: "keyboardBridge.handedOffRequestID") == snapshot.handledRequestID
            snapshot.phase = handedOff ? .error : (alreadyInserted ? .inserted : phase)
            snapshot.processingStage = processingStage
            snapshot.liveText = liveText
            snapshot.cachedText = cachedText
            snapshot.finalText = finalText
            snapshot.errorText = handedOff ? "修改失败,新稿已复制" : errorText
            snapshot.needsForeground = needsForeground
            snapshot.canStartRecordingInBackground = canStartRecordingInBackground
            snapshot.appHeartbeatAt = Date().timeIntervalSince1970
            snapshot.resultRequestID = phase == .ready && !alreadyInserted && !handedOff ? snapshot.handledRequestID : nil
            snapshot.audioLevel = audioLevel
        }
    }

    /// 键盘录音键波形的高频同步通道(0.1s 节流,见 `DictationController.ingestAudioLevel`)。
    /// 只写这一个字段,不动快照其余部分——比走整套 `publishAppState` 轻,配合键盘侧的
    /// `levelTimer` 专用读取,不搭常规 0.5s 桥轮询的车。
    static func publishAudioLevel(_ level: Float) {
        publish { snapshot in snapshot.audioLevel = level }
    }

    /// 修改请求消费/放弃后清掉 `editBaseText`,防止残留值把后面某次普通口述的交付
    /// 误判成修改结果。`requestRecording` 发起新的普通请求时也会清一次,这里是
    /// 修改流程自己结束时的及时清理,双保险。
    static func clearEditBaseText() {
        publish { snapshot in snapshot.editBaseText = nil; snapshot.editTarget = nil }
    }

    static func markInserted(_ text: String, requestID: String? = nil) {
        let id = requestID ?? snapshot().resultRequestID
        if let id { suite?.set(id, forKey: "keyboardBridge.insertedRequestID") }
        publish { snapshot in
            snapshot.phase = .inserted
            snapshot.insertedText = text
            snapshot.resultRequestID = nil
        }
    }

    static func markHandedOff(requestID: String?) {
        guard let requestID else { return }
        suite?.set(requestID, forKey: "keyboardBridge.handedOffRequestID")
        publish { snapshot in
            snapshot.phase = .error
            snapshot.insertedText = ""
            snapshot.errorText = "修改失败,新稿已复制"
            snapshot.resultRequestID = nil
        }
    }

    /// Bind only the first reconnect in the target process. Later field switches
    /// must not retarget a pending result to another document.
    static func bindReturnedDocument(_ documentID: UUID, hostPID: Int) {
        publish { snapshot in
            guard let target = snapshot.returnTarget, target.pid == hostPID,
                  snapshot.returnedDocumentID == nil,
                  snapshot.insertedText.isEmpty,
                  [.recording, .processing, .ready].contains(snapshot.phase) else { return }
            snapshot.returnedDocumentID = documentID
        }
    }

    static func isAppAwake(now: TimeInterval = Date().timeIntervalSince1970,
                           maxAge: TimeInterval = awakeTTL) -> Bool {
        let heartbeat = snapshot().appHeartbeatAt
        return heartbeat > 0 && now - heartbeat <= maxAge
    }

    /// opening/recording/processing 是瞬时进程状态，主 App 被杀后不能永久残留在键盘上。
    /// ready/inserted 等结果态仍允许跨进程保留。
    static func effectivePhase(_ snapshot: KeyboardBridgeSnapshot,
                               now: TimeInterval = Date().timeIntervalSince1970) -> KeyboardBridgePhase {
        let transient = snapshot.phase == .opening || snapshot.phase == .recording || snapshot.phase == .processing
        guard transient else { return snapshot.phase }
        let heartbeatIsFresh = snapshot.appHeartbeatAt > 0 && now - snapshot.appHeartbeatAt <= awakeTTL
        return heartbeatIsFresh ? snapshot.phase : .idle
    }

    static func canAcceptDirectKeyboardRequest(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let snapshot = snapshot()
        guard snapshot.appHeartbeatAt > 0,
              now - snapshot.appHeartbeatAt <= directRequestTTL,
              snapshot.canStartRecordingInBackground == true else {
            return false
        }
        return snapshot.requestID.isEmpty || snapshot.requestID == snapshot.handledRequestID
    }

    // MARK: - Action Button → 当前 Shall We Talk 键盘

    /// 由键盘扩展持续刷新的短心跳。`sessionID` 仅用来防止旧键盘实例
    /// 在消失回调中把新实例刚写入的在线状态清掉。
    static func publishKeyboardPresence(sessionID: String,
                                        documentID: UUID,
                                        now: TimeInterval = Date().timeIntervalSince1970) {
        guard let suite else { return }
        let presence = KeyboardPresence(
            sessionID: sessionID,
            target: KeyboardInsertionTarget(documentID: documentID),
            updatedAt: now
        )
        guard let data = try? JSONEncoder().encode(presence) else { return }
        suite.set(data, forKey: keyboardPresenceKey)
    }

    static func clearKeyboardPresence(sessionID: String) {
        guard let suite,
              let presence = keyboardPresence(from: suite),
              presence.sessionID == sessionID else { return }
        suite.removeObject(forKey: keyboardPresenceKey)
    }

    /// Action Button 开始时取一次快照；没有完全访问或键盘不在前台时返回 nil。
    static func activeKeyboardInsertionTarget(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = keyboardPresenceTTL
    ) -> KeyboardInsertionTarget? {
        guard let suite, let presence = keyboardPresence(from: suite) else { return nil }
        let age = now - presence.updatedAt
        guard age >= 0, age <= maxAge else { return nil }
        return presence.target
    }

    /// 将 Action Button 结果投递给当前仍活跃的同一输入文档。
    /// 文本仍由 `PendingTextStore` 的 request-bound 事务槽保护，这里只额外保存
    /// 目标文档，供键盘在消费前做最后一次身份校验。
    @discardableResult
    static func publishActionKeyboardDelivery(
        _ text: String,
        to target: KeyboardInsertionTarget,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> String? {
        guard !text.isEmpty,
              activeKeyboardInsertionTarget(now: now) == target,
              let suite else { return nil }

        let requestID = "action:\(UUID().uuidString)"
        guard PendingTextStore.push(text, requestID: requestID) else { return nil }
        let delivery = ActionKeyboardDelivery(requestID: requestID, target: target, createdAt: now)
        guard let data = try? JSONEncoder().encode(delivery) else {
            PendingTextStore.clear()
            return nil
        }
        suite.set(data, forKey: actionKeyboardDeliveryKey)
        DarwinBridge.post(DarwinBridge.evtResult)
        return requestID
    }

    /// 只向正处在目标输入文档的键盘暴露请求 ID。
    static func pendingActionKeyboardDelivery(
        for documentID: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> String? {
        guard let suite,
              let data = suite.data(forKey: actionKeyboardDeliveryKey),
              let delivery = try? JSONDecoder().decode(ActionKeyboardDelivery.self, from: data) else {
            return nil
        }
        let age = now - delivery.createdAt
        guard age >= 0, age <= actionKeyboardDeliveryTTL else {
            suite.removeObject(forKey: actionKeyboardDeliveryKey)
            return nil
        }
        guard delivery.target.documentID == documentID,
              activeKeyboardInsertionTarget(now: now) == delivery.target else {
            // 交付发布后若用户立即切换了输入框/宿主，直接取消这次
            // 自动插入；不允许他稍后切回旧输入框时突然收到陈旧文字。
            suite.removeObject(forKey: actionKeyboardDeliveryKey)
            return nil
        }
        return delivery.requestID
    }

    static func acknowledgeActionKeyboardDelivery(_ requestID: String) {
        guard let suite,
              let data = suite.data(forKey: actionKeyboardDeliveryKey),
              let delivery = try? JSONDecoder().decode(ActionKeyboardDelivery.self, from: data),
              delivery.requestID == requestID else { return }
        suite.removeObject(forKey: actionKeyboardDeliveryKey)
    }

    private static func keyboardPresence(from suite: UserDefaults) -> KeyboardPresence? {
        guard let data = suite.data(forKey: keyboardPresenceKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardPresence.self, from: data)
    }

    static func clear() {
        suite?.removeObject(forKey: snapshotKey)
    }
}


/// One observed identity carried in the same snapshot as its recording request.
/// Time is the original observation, never renewed when a cached value is reused.
struct HostReturnTarget: Codable, Equatable {
    let pid: Int
    let bundleID: String
    let observedAt: TimeInterval
    let documentID: UUID

    func isValid(now: TimeInterval) -> Bool {
        pid > 0 && pid <= Int(Int32.max) && now.isFinite && observedAt.isFinite &&
        now >= observedAt && now - observedAt <= 60 && bundleID.count <= 255 &&
        !bundleID.hasPrefix("org.example.") &&
        bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    func isValidForReturn(requestAt: TimeInterval, now: TimeInterval) -> Bool {
        isValid(now: now) && requestAt.isFinite && observedAt <= requestAt &&
        now >= requestAt && now - requestAt <= 5
    }
}
