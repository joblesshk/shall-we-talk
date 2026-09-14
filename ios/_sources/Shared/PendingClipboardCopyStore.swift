import Foundation

/// A failed shortcut copy may be retried on the next foreground activation.
/// Separate from keyboard delivery: never expose this text to a different field.
final class PendingClipboardCopyStore {
    private struct Payload: Codable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date
    }
    private let defaults: UserDefaults
    private let key = "pendingShortcutClipboardCopy.v1"
    static let lifetime: TimeInterval = 120

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func enqueue(_ text: String, now: Date = Date()) {
        guard !text.isEmpty else { clear(); return }
        let value = Payload(id: UUID(), text: text, createdAt: now)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func clear() { defaults.removeObject(forKey: key) }

    /// Returns copied text only after the writer verifies success. Call on the
    /// main actor, with the app active; an unsuccessful write retains the payload.
    func retry(now: Date = Date(), copy: (String) -> Bool) -> String? {
        guard let payload = load() else { clear(); return nil }
        let age = now.timeIntervalSince(payload.createdAt)
        guard age >= 0, age <= Self.lifetime else { clear(); return nil }
        guard copy(payload.text) else { return nil }
        if load() == payload { clear() }
        return payload.text
    }

    private func load() -> Payload? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
