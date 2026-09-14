import Foundation

@main struct PendingClipboardCopySmoke {
    static func main() {
        let suite = "clipboard-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PendingClipboardCopyStore(defaults: defaults)
        let now = Date()
        store.enqueue("first", now: now)
        assert(store.retry(now: now, copy: { _ in false }) == nil)
        let relaunched = PendingClipboardCopyStore(defaults: defaults)
        assert(relaunched.retry(now: now, copy: { $0 == "first" }) == "first")
        assert(store.retry(now: now, copy: { _ in fatalError("duplicate copy") }) == nil)
        store.enqueue("expired", now: now)
        assert(store.retry(now: now.addingTimeInterval(121), copy: { _ in fatalError("expired copy") }) == nil)
        store.enqueue("future", now: now.addingTimeInterval(10))
        assert(store.retry(now: now, copy: { _ in fatalError("future copy") }) == nil)
        store.enqueue("old", now: now)
        store.enqueue("new", now: now)
        assert(store.retry(now: now, copy: { $0 == "new" }) == "new")
        store.enqueue("cancelled", now: now)
        store.clear()
        assert(store.retry(now: now, copy: { _ in fatalError("cancelled copy") }) == nil)
        print("PASS: failed write, persistence, single delivery, expiry, clock reversal, supersession, cancellation")
    }
}
