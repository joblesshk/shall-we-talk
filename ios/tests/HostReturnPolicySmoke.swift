import Foundation

// Isolated bridge storage; never access production preferences in a smoke test.
enum AppGroup {
    static let id = "swt.host-return.tests.\(UUID().uuidString)"
    static let suite = UserDefaults(suiteName: id)
}
enum DarwinBridge {
    static let cmdKick = "test-kick"
    static let evtResult = "test-result"
    static func post(_ name: String) {}
}

@main
struct HostReturnPolicySmoke {
    static func main() throws {
        defer { AppGroup.suite?.removePersistentDomain(forName: AppGroup.id) }
        let doc = UUID()
        func target(_ pid: Int = 42, _ bundle: String = "com.apple.mobilenotes", _ at: Double = 100) -> HostReturnTarget {
            HostReturnTarget(pid: pid, bundleID: bundle, observedAt: at, documentID: doc)
        }
        precondition(target().isValidForReturn(requestAt: 120, now: 121))
        precondition(!target().isValidForReturn(requestAt: 120, now: 126))
        precondition(!target().isValidForReturn(requestAt: 99, now: 101))
        precondition(!target().isValid(now: 161))
        precondition(!target().isValid(now: 99))
        precondition(!target().isValid(now: .nan))
        precondition(!target(0).isValid(now: 101))
        precondition(!target(Int(Int32.max) + 1).isValid(now: 101))
        precondition(!target(42, "org.example.VoicePenMobile").isValid(now: 101))
        precondition(!target(42, "not a bundle").isValid(now: 101))
        precondition(!target(42, "com.apple.mobilenotes", .infinity).isValid(now: 101))
        let editTarget = KeyboardEditTarget(documentID: doc, hostPID: 42, before: "原文", after: "")
        precondition(editTarget.matches(documentID: doc, hostPID: 42, before: "原文", after: ""))
        precondition(!editTarget.matches(documentID: UUID(), hostPID: 42, before: "原文", after: ""))
        precondition(!editTarget.matches(documentID: doc, hostPID: 43, before: "原文", after: ""))
        precondition(!editTarget.matches(documentID: doc, hostPID: 42, before: "更晚修改", after: ""))
        precondition(!editTarget.matches(documentID: doc, hostPID: 42, before: "原", after: "文"))
        _ = KeyboardBridgeStore.requestEditRecording(baseText: "原文", target: editTarget)
        precondition(KeyboardBridgeStore.snapshot().editTarget == editTarget)
        _ = KeyboardBridgeStore.requestStopRecording()
        precondition(KeyboardBridgeStore.snapshot().editTarget == editTarget)
        KeyboardBridgeStore.clearEditBaseText()
        precondition(KeyboardBridgeStore.snapshot().editTarget == nil)
        // 真正执行生产替换算法：删空后 nil 上下文必须继续插入新稿。
        for emptyIsNil in [true, false] {
            var content = "旧稿👨‍👩‍👧‍👦é"
            let original = content
            var inserts = 0
            let target = KeyboardEditTarget(documentID: doc, hostPID: 42, before: content, after: nil)
            let result = KeyboardEditReplacement.perform(target: target, baseText: original, replacement: "新的完整稿",
                read: { KeyboardEditContext(documentID: doc, hostPID: 42,
                    before: content.isEmpty && emptyIsNil ? nil : content,
                    after: nil, hasText: !content.isEmpty) },
                deleteBackward: { content.removeLast() },
                insert: { content += $0; inserts += 1 })
            precondition(result == .inserted(deletions: original.count))
            precondition(content == "新的完整稿" && inserts == 1, "empty context must not strand an empty field")
        }
        // 两段口述只替换末段；同一位置连续修改仍保留第一段。
        var combined = "第一句话。第二句话。"
        for (base, replacement) in [("第二句话。", "改后的第二句。"), ("改后的第二句。", "再次修改的第二句。") ] {
            let scopedTarget = KeyboardEditTarget(documentID: doc, hostPID: 42, before: combined, after: nil)
            let result = KeyboardEditReplacement.perform(target: scopedTarget, baseText: base, replacement: replacement,
                read: { KeyboardEditContext(documentID: doc, hostPID: 42, before: combined, after: nil, hasText: !combined.isEmpty) },
                deleteBackward: { combined.removeLast() }, insert: { combined += $0 })
            precondition(result == .inserted(deletions: base.count))
            precondition(combined == "第一句话。" + replacement)
        }
        var deletes = 0
        let refusing = KeyboardEditTarget(documentID: doc, hostPID: 42, before: "原文", after: nil)
        let refused = KeyboardEditReplacement.perform(target: refusing, baseText: "原文", replacement: "新稿",
            read: { KeyboardEditContext(documentID: doc, hostPID: 42, before: "原文", after: nil, hasText: true) },
            deleteBackward: { deletes += 1 }, insert: { _ in preconditionFailure("must not append after refused deletion") })
        guard case .failed = refused else { preconditionFailure("refused delete cannot succeed") }
        precondition(deletes == 1)
        var switched = false
        let changed = KeyboardEditReplacement.perform(target: refusing, baseText: "原文", replacement: "新稿",
            read: { KeyboardEditContext(documentID: switched ? UUID() : doc, hostPID: 42,
                before: switched ? nil : "原文", after: nil, hasText: !switched) },
            deleteBackward: { switched = true }, insert: { _ in preconditionFailure("must not insert into a changed document") })
        guard case .failed = changed else { preconditionFailure("changed target cannot succeed") }
        let handoff = KeyboardBridgeStore.requestEditRecording(baseText: "原文", target: refusing)
        KeyboardBridgeStore.markRequestHandled(handoff)
        KeyboardBridgeStore.markHandedOff(requestID: handoff)
        KeyboardBridgeStore.publishAppState(phase: .ready, liveText: "", cachedText: "", finalText: "新稿")
        precondition(KeyboardBridgeStore.snapshot().phase == .error)
        precondition(KeyboardBridgeStore.snapshot().insertedText.isEmpty)
        precondition(KeyboardBridgeStore.snapshot().resultRequestID == nil)
        let id = KeyboardBridgeStore.requestRecording(returnTarget: target())
        let stored = KeyboardBridgeStore.snapshot()
        precondition(stored.requestID == id && stored.returnTarget == target())
        _ = KeyboardBridgeStore.requestStopRecording()
        precondition(KeyboardBridgeStore.snapshot().returnTarget == target(), "stop must preserve field ownership for delivery")
        _ = KeyboardBridgeStore.requestRecording()
        precondition(KeyboardBridgeStore.snapshot().returnTarget == nil, "a new hot request must not inherit old host identity")
        _ = KeyboardBridgeStore.requestRecording(returnTarget: target())
        _ = KeyboardBridgeStore.requestEditRecording(baseText: "test")
        precondition(KeyboardBridgeStore.snapshot().returnTarget == nil, "edit must not inherit an unrelated recording target")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
        legacy.removeValue(forKey: "returnTarget")
        let decoded = try JSONDecoder().decode(KeyboardBridgeSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.returnTarget == nil, "upgrade must decode legacy snapshots")
        let next = KeyboardBridgeStore.requestRecording(returnTarget: target())
        KeyboardBridgeStore.markRequestHandled(next)
        KeyboardBridgeStore.publishAppState(phase: .recording, liveText: "草稿", cachedText: "", finalText: "")
        let returned = UUID()
        KeyboardBridgeStore.bindReturnedDocument(returned, hostPID: 99)
        precondition(KeyboardBridgeStore.snapshot().returnedDocumentID == nil)
        KeyboardBridgeStore.bindReturnedDocument(returned, hostPID: 42)
        precondition(KeyboardBridgeStore.snapshot().returnedDocumentID == returned)
        KeyboardBridgeStore.bindReturnedDocument(UUID(), hostPID: 42)
        precondition(KeyboardBridgeStore.snapshot().returnedDocumentID == returned, "another field cannot steal the reconnect")
        KeyboardBridgeStore.publishAppState(phase: .ready, liveText: "草稿", cachedText: "", finalText: "整理稿")
        KeyboardBridgeStore.markInserted("整理稿", requestID: next)
        for _ in 0..<3 {
            KeyboardBridgeStore.publishAppState(phase: .ready, liveText: "草稿", cachedText: "", finalText: "整理稿")
            precondition(KeyboardBridgeStore.snapshot().phase == .inserted)
            precondition(KeyboardBridgeStore.snapshot().resultRequestID == nil, "heartbeat cannot resurrect delivery")
        }
        _ = KeyboardBridgeStore.requestRecording()
        precondition(KeyboardBridgeStore.snapshot().phase == .opening)
        precondition(KeyboardBridgeStore.snapshot().insertedText.isEmpty)
        precondition(KeyboardBridgeStore.snapshot().returnedDocumentID == nil)
        print("PASS: host-return policy, reconnect, heartbeat acknowledgement and next-recording checks")
    }
}
