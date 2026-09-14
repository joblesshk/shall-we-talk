import Foundation
import Combine

enum AppDataDirectory {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-review-" + UUID().uuidString)
    static func url() -> URL { directory }
}
enum DiagLog { static func log(_ component: String, _ message: String) {} }

@main enum TodoStorePersistenceSmoke {
    static func main() throws {
        let fm = FileManager.default, base = AppDataDirectory.directory
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("todos.json")
        let seed = TodoItem(id: UUID(), text: "original", createdAt: Date(), done: false, completedAt: nil)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        let store = TodoStore()
        try fm.removeItem(at: file)
        try JSONEncoder().encode([seed]).write(to: file)
        _ = store.add(["new"])
        let recovered = try JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: file))
        precondition(recovered.contains { $0.id == seed.id }, "read failure overwrote existing todo")
        precondition(recovered.contains { $0.text == "new" }, "recovery lost new todo")
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        _ = store.add(["pending"])
        precondition(store.persistenceError != nil)
        try fm.removeItem(at: file)
        precondition(store.retryPersistence())
        precondition(TodoStore().items.contains { $0.text == "pending" })
        print("PASS: todo read recovery preserves old/new items and retries failed writes")
    }
}
