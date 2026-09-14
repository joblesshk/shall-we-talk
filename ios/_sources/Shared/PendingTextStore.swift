import Darwin
import Foundation
#if os(iOS)
import UIKit
#endif

/// App Group 内的单条待回填结果。文本、请求归属和时间戳作为一个
/// Codable payload 一次写入，避免旧版三个 UserDefaults key 的部分更新。
private struct PendingTextPayload: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let payloadID: String
    let requestID: String
    let text: String
    let createdAt: TimeInterval
}

/// 键盘对一次待回填结果的消费结果。
enum PendingTextConsumption: Equatable {
    /// 宿主已接受文本，对应 payload 也已精确确认。
    case inserted(String)
    /// 自动写入未完成；调用方已保存结果并转为人工交付，不得显示插入成功。
    case handedOff(String)
    /// 其他 App/键盘进程正在修改同一交付槽；数据未动，稍后重试。
    case busy
    /// 当前没有属于该 request ID 的有效结果。
    case none
}

/// 主 App 与键盘扩展之间的文字接力。
///
/// App Group 模式采用跨进程排他锁：主 App 在锁内发布完整 payload；键盘在
/// 同一锁内重读并核对 request/payload ID，让宿主插入，再删除该精确 payload
/// 并发布 inserted 确认。这可以消除“先 pop/删除，后 insert”的丢文窗口，
/// 也防止多个键盘实例同时消费。
enum PendingTextStore {
    static let appGroupID = AppGroup.id
    private static var suite: UserDefaults? { AppGroup.suite }
    private static var lockFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("pending-text-delivery.lock", isDirectory: false)
    }

    private static let payloadKey = "pendingTextPayload.v2"
    private static let legacyTextKey = "pendingText"
    private static let legacyAtKey = "pendingAt"
    private static let legacyRequestIDKey = "pendingRequestID"
    private static let pasteboardMarkerType = "org.example.show-we-talk.pending-text"
    private static let plainTextType = "public.utf8-plain-text"
    private static let publishRetryDelays: [TimeInterval] = [0, 0.002, 0.005, 0.01, 0.02, 0.04]

    /// 结果有效期：3 分钟内未被键盘取走则作废，避免陈旧文字误插。
    static let ttl: TimeInterval = 180

    /// 发布一条与键盘请求精确绑定的结果。
    /// - Returns: App Group 模式下表示是否在有界重试内成功发布；
    ///   剪贴板降级模式下表示是否成功写入。
    @discardableResult
    static func push(_ text: String, requestID: String? = nil) -> Bool {
        if let storage = suite {
            guard let requestID, !requestID.isEmpty, !text.isEmpty,
                  let lockFileURL else { return false }
            return publish(
                text,
                requestID: requestID,
                storage: storage,
                lockFileURL: lockFileURL,
                now: Date().timeIntervalSince1970
            )
        }
        #if os(iOS)
        let payload: [String: Any] = ["text": text, "at": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let marker = String(data: data, encoding: .utf8) else {
            UIPasteboard.general.string = text
            return true
        }
        UIPasteboard.general.items = [[
            plainTextType: text,
            pasteboardMarkerType: marker
        ]]
        return true
        #else
        return false
        #endif
    }

    /// Action Button / 快捷指令的通用语音输入不属于某个键盘请求，
    /// 因此不写 App Group 交付槽，只把整理稿发布到系统剪贴板。
    /// 保持为纯文本 item，让系统键盘有机会把它显示为快速粘贴建议。
    @MainActor
    @discardableResult
    static func copyToSystemPasteboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        #if os(iOS)
        // `items` 是个返回 Void 的 setter:**赋值不抛错不等于文字进了系统剪贴板**。
        // 通用剪贴板的闸门是"进程此刻有没有前台资格",而 Action 交付发生在被系统拉起的
        // 后台无窗口进程里,写入会被静默挡下。此前这里无条件 `return true`,导致
        // `captureClipboardCopied` 恒为真、失败分支成为死代码、灵动岛恒称"已复制"——
        // 程序从来没有真正测量过这件事(2026-09-01)。
        //
        // `changeCount` 是单调递增的版本号,任何 App 写入都会 +1,写前写后比对是唯一可靠
        // 的判据。读它不算一次剪贴板读取访问,不会触发系统的"粘贴自"提示。剪贴板服务在
        // 后台完全不可用时两次都读到 0,同样正确地落在"失败"上——降级是安全的。
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.items = [[plainTextType: text]]
        let after = UIPasteboard.general.changeCount
        let ok = after != before
        DiagLog.log("clipboard",
                    "写入剪贴板 changeCount \(before)→\(after) 判定=\(ok ? "成功" : "失败")")
        return ok
        #else
        return false
        #endif
    }

    /// 在交易内把文本交给当前宿主。`insert` 返回后才会删除精确匹配的
    /// payload；获锁失败则返回 `.busy`，保留结果等待下一次轮询。
    static func consume(
        expectedRequestID: String?,
        allowPlainTextFallback: Bool = false,
        insert: (String) -> Void,
        acknowledge: (String) -> Void,
        didInsert: () -> Bool = { true }
    ) -> PendingTextConsumption {
        if let storage = suite {
            guard let expectedRequestID, !expectedRequestID.isEmpty,
                  let lockFileURL else { return .none }
            return consume(
                expectedRequestID: expectedRequestID,
                storage: storage,
                lockFileURL: lockFileURL,
                now: Date().timeIntervalSince1970,
                insert: insert,
                acknowledge: acknowledge,
                didInsert: didInsert
            )
        }

        #if os(iOS)
        for item in UIPasteboard.general.items {
            guard let marker = item[pasteboardMarkerType] as? String,
                  let data = marker.data(using: .utf8),
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = payload["text"] as? String, !text.isEmpty,
                  let at = payload["at"] as? TimeInterval else { continue }
            UIPasteboard.general.string = text
            guard Date().timeIntervalSince1970 - at < ttl else { return .none }
            insert(text)
            guard didInsert() else { return .handedOff(text) }
            acknowledge(text)
            return .inserted(text)
        }
        if allowPlainTextFallback,
           let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            insert(text)
            guard didInsert() else { return .handedOff(text) }
            acknowledge(text)
            return .inserted(text)
        }
        #endif
        return .none
    }

    /// 新请求开始或非键盘路由时清空交付槽。锁忙时不强行删除；
    /// request ID 校验仍会阻止旧结果误插，后续发布会覆盖它。
    @discardableResult
    static func clear() -> Bool {
        guard let storage = suite else { return true }
        guard let lockFileURL else { return false }
        return retryingLock {
            withLock(at: lockFileURL) {
                storage.synchronize()
                removeAllPayloadKeys(from: storage)
                storage.synchronize()
                return true
            }
        } ?? false
    }

    private static func publish(
        _ text: String,
        requestID: String,
        storage: UserDefaults,
        lockFileURL: URL,
        now: TimeInterval
    ) -> Bool {
        let payload = PendingTextPayload(
            schemaVersion: PendingTextPayload.currentSchemaVersion,
            payloadID: UUID().uuidString,
            requestID: requestID,
            text: text,
            createdAt: now
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        return retryingLock {
            withLock(at: lockFileURL) {
                storage.synchronize()
                if (storage.stringArray(forKey: "pendingText.consumedRequests.v1") ?? []).contains(requestID) {
                    return true
                }

                storage.set(data, forKey: payloadKey)
                removeLegacyKeys(from: storage)
                storage.synchronize()
                return true
            }
        } ?? false
    }

    private static func consume(
        expectedRequestID: String,
        storage: UserDefaults,
        lockFileURL: URL,
        now: TimeInterval,
        insert: (String) -> Void,
        acknowledge: (String) -> Void,
        didInsert: () -> Bool = { true }
    ) -> PendingTextConsumption {
        guard let result = withLock(at: lockFileURL, {
            storage.synchronize()
            guard let payload = currentPayload(in: storage),
                  payload.requestID == expectedRequestID,
                  !payload.text.isEmpty else { return PendingTextConsumption.none }

            guard now - payload.createdAt < ttl else {
                removePayload(ifMatching: payload, from: storage)
                storage.synchronize()
                return .none
            }

            var consumed = storage.stringArray(forKey: "pendingText.consumedRequests.v1") ?? []
            guard !consumed.contains(expectedRequestID) else {
                removePayload(ifMatching: payload, from: storage)
                storage.synchronize()
                return .none
            }
            // 调用宿主插入时仍持有跨进程锁，两个键盘实例不可能同时越过此处。
            insert(payload.text)
            consumed.append(expectedRequestID)
            storage.set(Array(consumed.suffix(32)), forKey: "pendingText.consumedRequests.v1")
            removePayload(ifMatching: payload, from: storage)
            let inserted = didInsert()
            if inserted { acknowledge(payload.text) }
            storage.synchronize()
            return inserted ? .inserted(payload.text) : .handedOff(payload.text)
        }) else {
            return .busy
        }
        return result
    }

    private static func currentPayload(in storage: UserDefaults) -> PendingTextPayload? {
        if let data = storage.data(forKey: payloadKey),
           let payload = try? JSONDecoder().decode(PendingTextPayload.self, from: data),
           payload.schemaVersion == PendingTextPayload.currentSchemaVersion {
            return payload
        }

        // 升级兼容：旧版三 key payload 只在锁内读取。用其内容生成稳定 ID，
        // 以便 removePayload 在删除前能再次精确复核。
        guard let requestID = storage.string(forKey: legacyRequestIDKey), !requestID.isEmpty,
              let text = storage.string(forKey: legacyTextKey), !text.isEmpty else { return nil }
        let createdAt = storage.double(forKey: legacyAtKey)
        return PendingTextPayload(
            schemaVersion: 1,
            payloadID: "legacy:\(requestID):\(createdAt):\(text.utf8.count)",
            requestID: requestID,
            text: text,
            createdAt: createdAt
        )
    }

    private static func removePayload(ifMatching expected: PendingTextPayload, from storage: UserDefaults) {
        guard currentPayload(in: storage)?.payloadID == expected.payloadID else { return }
        removeAllPayloadKeys(from: storage)
    }

    private static func removeAllPayloadKeys(from storage: UserDefaults) {
        storage.removeObject(forKey: payloadKey)
        removeLegacyKeys(from: storage)
    }

    private static func removeLegacyKeys(from storage: UserDefaults) {
        storage.removeObject(forKey: legacyTextKey)
        storage.removeObject(forKey: legacyAtKey)
        storage.removeObject(forKey: legacyRequestIDKey)
    }

    /// 主 App 发布可以容忍键盘正处在极短的插入临界区，但绝不无界阻塞。
    private static func retryingLock<T>(_ operation: () -> T?) -> T? {
        for delay in publishRetryDelays {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if let result = operation() { return result }
        }
        return nil
    }

    /// 返回 nil 仅表示锁正被其他进程持有；body 本身可以返回 Optional。
    private static func withLock<T>(at url: URL, _ body: () -> T) -> T? {
        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return nil }
        _ = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return body()
    }

    #if DEBUG
    /// Foundation-only 回归测试注入口；不进入 Release 二进制的公开 API。
    static func _pushForTesting(
        _ text: String,
        requestID: String,
        storage: UserDefaults,
        lockFileURL: URL,
        now: TimeInterval
    ) -> Bool {
        publish(text, requestID: requestID, storage: storage, lockFileURL: lockFileURL, now: now)
    }

    static func _consumeForTesting(
        expectedRequestID: String,
        storage: UserDefaults,
        lockFileURL: URL,
        now: TimeInterval,
        insert: (String) -> Void,
        acknowledge: (String) -> Void = { _ in },
        didInsert: () -> Bool = { true }
    ) -> PendingTextConsumption {
        consume(
            expectedRequestID: expectedRequestID,
            storage: storage,
            lockFileURL: lockFileURL,
            now: now,
            insert: insert,
            acknowledge: acknowledge,
                didInsert: didInsert
        )
    }
    #endif
}
