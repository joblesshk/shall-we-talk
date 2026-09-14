import Darwin
import Foundation

// PendingTextStore.swift 的 macOS Foundation-only 测试桩；真实 App Group 由测试
// 显式注入 UserDefaults + lock URL，不读写开发机上的生产容器。
enum AppGroup {
    static let id = "group.org.example.voicepen.tests"
    static var suite: UserDefaults? { nil }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@main
private enum PendingTextTransactionSmoke {
    static func main() throws {
        let domain = "org.example.voicepen.pending-tests.\(UUID().uuidString)"
        guard let storage = UserDefaults(suiteName: domain) else {
            throw Failure(description: "cannot create isolated UserDefaults suite")
        }
        storage.removePersistentDomain(forName: domain)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepen-pending-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("delivery.lock")
        defer {
            storage.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        try testUnicodeAndMiddleCursor(storage: storage, lockURL: lockURL)
        try testRequestOwnershipAndExpiry(storage: storage, lockURL: lockURL)
        try testBusyLockPreservesPayload(storage: storage, lockURL: lockURL)
        try testConcurrentConsumersInsertExactlyOnce(storage: storage, lockURL: lockURL)
        try testRapidSequentialRequests(storage: storage, lockURL: lockURL)
        try testManualHandoff(storage: storage, lockURL: lockURL)
        try testReplayedDelivery(storage: storage, lockURL: lockURL)
        print("PASS: pending text transaction smoke (Unicode/cursor/ownership/expiry/lock/concurrency/rapid-repeat)")
    }

    private static func testManualHandoff(storage: UserDefaults, lockURL: URL) throws {
        let request = "edit:manual-handoff"
        try require(PendingTextStore._pushForTesting("新稿", requestID: request,
            storage: storage, lockFileURL: lockURL, now: 2100), "publish manual handoff")
        var copied = "", acknowledged = false
        let result = PendingTextStore._consumeForTesting(expectedRequestID: request,
            storage: storage, lockFileURL: lockURL, now: 2101,
            insert: { copied = $0 }, acknowledge: { _ in acknowledged = true }, didInsert: { false })
        try require(result == .handedOff("新稿") && copied == "新稿", "failed edit must retain manual result")
        try require(!acknowledged, "failed edit cannot acknowledge insertion")
        let repeated = PendingTextStore._consumeForTesting(expectedRequestID: request,
            storage: storage, lockFileURL: lockURL, now: 2102,
            insert: { _ in acknowledged = true })
        try require(repeated == .none && !acknowledged, "manual handoff cannot repeat a destructive edit")
    }

    private static func testReplayedDelivery(storage: UserDefaults, lockURL: URL) throws {
        var received: [String] = []
        for _ in 0..<3 {
            try require(PendingTextStore._pushForTesting("整理后的最终稿", requestID: "record:replayed-final",
                storage: storage, lockFileURL: lockURL, now: 2000), "publish replay")
            _ = PendingTextStore._consumeForTesting(expectedRequestID: "record:replayed-final",
                storage: storage, lockFileURL: lockURL, now: 2001,
                insert: { received.append($0) }, acknowledge: { _ in })
        }
        try require(received == ["整理后的最终稿"], "same request must insert only once even after republication")
        try require(PendingTextStore._pushForTesting("下一段", requestID: "record:next-final",
            storage: storage, lockFileURL: lockURL, now: 2002), "publish next recording")
        _ = PendingTextStore._consumeForTesting(expectedRequestID: "record:next-final",
            storage: storage, lockFileURL: lockURL, now: 2003,
            insert: { received.append($0) }, acknowledge: { _ in })
        try require(received == ["整理后的最终稿", "下一段"], "next recording must still insert normally")
    }

    private static func testUnicodeAndMiddleCursor(storage: UserDefaults, lockURL: URL) throws {
        let now = 1_000.0
        let text = String(repeating: "中👨‍👩‍👧‍👦é\n", count: 1_024)
        try require(PendingTextStore._pushForTesting(
            text, requestID: "record:unicode", storage: storage, lockFileURL: lockURL, now: now
        ), "long Unicode payload was not published")

        var host = "前缀|后缀"
        let cursor = host.firstIndex(of: "|")!
        host.remove(at: cursor)
        var acknowledged = ""
        let result = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:unicode",
            storage: storage,
            lockFileURL: lockURL,
            now: now + 1,
            insert: { host.insert(contentsOf: $0, at: cursor) },
            acknowledge: { acknowledged = $0 }
        )
        try require(result == .inserted(text), "Unicode result was not inserted")
        try require(host == "前缀\(text)后缀", "middle-cursor insertion changed text or position")
        try require(acknowledged == text, "acknowledgement did not carry the exact inserted text")
        try require(
            PendingTextStore._consumeForTesting(
                expectedRequestID: "record:unicode", storage: storage, lockFileURL: lockURL,
                now: now + 2, insert: { _ in }
            ) == .none,
            "consumed payload remained available"
        )
    }

    private static func testRequestOwnershipAndExpiry(storage: UserDefaults, lockURL: URL) throws {
        try require(PendingTextStore._pushForTesting(
            "owned", requestID: "record:owner", storage: storage, lockFileURL: lockURL, now: 2_000
        ), "owned payload was not published")
        var inserts = 0
        let mismatch = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:other", storage: storage, lockFileURL: lockURL,
            now: 2_001, insert: { _ in inserts += 1 }
        )
        try require(mismatch == .none && inserts == 0, "wrong request consumed another request's payload")
        let owner = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:owner", storage: storage, lockFileURL: lockURL,
            now: 2_002, insert: { _ in inserts += 1 }
        )
        try require(owner == .inserted("owned") && inserts == 1, "request mismatch deleted the owned payload")

        try require(PendingTextStore._pushForTesting(
            "stale", requestID: "record:stale", storage: storage, lockFileURL: lockURL, now: 3_000
        ), "stale fixture was not published")
        let stale = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:stale", storage: storage, lockFileURL: lockURL,
            now: 3_000 + PendingTextStore.ttl, insert: { _ in inserts += 1 }
        )
        try require(stale == .none && inserts == 1, "expired payload was inserted")
    }

    private static func testBusyLockPreservesPayload(storage: UserDefaults, lockURL: URL) throws {
        try require(PendingTextStore._pushForTesting(
            "preserve-me", requestID: "record:busy", storage: storage, lockFileURL: lockURL, now: 4_000
        ), "busy-lock fixture was not published")

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        try require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "cannot hold fixture lock")
        let blocked = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:busy", storage: storage, lockFileURL: lockURL,
            now: 4_001, insert: { _ in throwAwayFailure("insert ran while lock was held") }
        )
        try require(blocked == .busy, "lock contention was not reported as retryable busy")
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)

        var inserted = ""
        let retried = PendingTextStore._consumeForTesting(
            expectedRequestID: "record:busy", storage: storage, lockFileURL: lockURL,
            now: 4_002, insert: { inserted = $0 }
        )
        try require(retried == .inserted("preserve-me") && inserted == "preserve-me",
                    "busy attempt deleted or changed the payload")
    }

    private static func testConcurrentConsumersInsertExactlyOnce(storage: UserDefaults, lockURL: URL) throws {
        try require(PendingTextStore._pushForTesting(
            "once", requestID: "record:race", storage: storage, lockFileURL: lockURL, now: 5_000
        ), "race fixture was not published")

        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let insertedTexts = LockedBox<[String]>([])
        let outcomes = LockedBox<[PendingTextConsumption]>([])
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                let result = PendingTextStore._consumeForTesting(
                    expectedRequestID: "record:race", storage: storage, lockFileURL: lockURL,
                    now: 5_001,
                    insert: { text in insertedTexts.withValue { $0.append(text) } }
                )
                outcomes.withValue { $0.append(result) }
                group.leave()
            }
        }
        for _ in 0..<32 { start.signal() }
        try require(group.wait(timeout: .now() + 5) == .success, "concurrent consumers timed out")
        let inserted = insertedTexts.withValue { $0 }
        let results = outcomes.withValue { $0 }
        try require(inserted == ["once"], "concurrent consumers inserted \(inserted.count) times")
        try require(results.filter { $0 == .inserted("once") }.count == 1,
                    "transaction did not produce exactly one successful consumer")
    }

    private static func testRapidSequentialRequests(storage: UserDefaults, lockURL: URL) throws {
        var host: [String] = []
        for index in 0..<250 {
            let requestID = "record:rapid:\(index)"
            let text = "\(index)-🎙️-中文"
            try require(PendingTextStore._pushForTesting(
                text, requestID: requestID, storage: storage, lockFileURL: lockURL,
                now: 6_000 + Double(index)
            ), "rapid request \(index) failed to publish")
            let result = PendingTextStore._consumeForTesting(
                expectedRequestID: requestID, storage: storage, lockFileURL: lockURL,
                now: 6_000.5 + Double(index), insert: { host.append($0) }
            )
            try require(result == .inserted(text), "rapid request \(index) failed to consume")
        }
        try require(host.count == 250 && Set(host).count == 250, "rapid requests were lost or duplicated")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func throwAwayFailure(_ message: String) {
        fputs("UNEXPECTED: \(message)\n", stderr)
    }
}
