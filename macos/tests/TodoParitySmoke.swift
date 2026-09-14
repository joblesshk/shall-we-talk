import Foundation

enum AppDataDirectory {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-todo-parity-" + UUID().uuidString)
    static func url() -> URL { directory }
}

@main struct TodoParitySmoke {
    static func main() throws {
        defer { try? FileManager.default.removeItem(at: AppDataDirectory.directory) }
        let old = Data(#"{"id":"11111111-1111-1111-1111-111111111111","text":"旧待办","createdAt":100,"done":false}"#.utf8)
        let migrated = try JSONDecoder().decode(TodoItem.self, from: old)
        precondition(migrated.sourceRecordID == nil && migrated.sourceRawText == nil)
        let store = TodoStore()
        let source = UUID()
        let group = store.add(["联系客户", "提交材料"], sourceRecordID: source, sourceRawText: "提醒我联系客户，提交材料")
        let other = store.add(["另一场口述"])
        let replacement = store.replaceRecordingGroup(containing: group[0], with: ["联系甲客户", "联系乙客户", "提交材料"])!
        precondition(replacement.items.count == 3 && store.items.count == 4)
        precondition(store.items.contains { $0.id == other[0].id })
        precondition(replacement.items.allSatisfy { $0.sourceRecordID == source && $0.sourceRawText == group[0].sourceRawText })
        precondition(store.updateText(replacement.items[0].id, text: " ") == nil)
        precondition(store.updateText(replacement.items[0].id, text: "编辑后的事项")?.text == "编辑后的事项")
        precondition(store.retryPersistence())
        precondition(TodoStore().items.count == 4)
        let original = store.recordingGroup(containing: replacement.items[0])
        precondition(original.count == 3)
        precondition(store.isCurrentCalendarRequest(original[1]))
        _ = store.updateText(original[1].id, text: "请求期间手动编辑")
        precondition(!store.isCurrentCalendarRequest(original[1]))
        precondition(store.replaceRecordingGroup(containing: original[0], with: ["迟到结果"], expectedGroup: original) == nil)
        let edited = store.recordingGroup(containing: original[0])
        store.toggle(edited[1].id)
        precondition(!store.isCurrentCalendarRequest(edited[1]))
        precondition(store.replaceRecordingGroup(containing: edited[0], with: ["迟到结果"], expectedGroup: edited) == nil)
        let toggled = store.recordingGroup(containing: original[0])
        store.delete(toggled[1].id)
        precondition(!store.isCurrentCalendarRequest(toggled[1]))
        precondition(store.replaceRecordingGroup(containing: toggled[0], with: ["迟到结果"], expectedGroup: toggled) == nil)
        let current = store.recordingGroup(containing: original[0])
        precondition(store.replaceRecordingGroup(containing: current[0], with: ["正常结果"], expectedGroup: current)?.items.count == 1)
        precondition(store.recordingGroup(containing: original[0]).isEmpty)
        let calendarItem = store.add(["日历请求快照"])[0]
        precondition(store.isCurrentCalendarRequest(calendarItem))
        store.setCalendarEventIdentifier("synthetic-event-id", for: calendarItem.id)
        precondition(!store.isCurrentCalendarRequest(calendarItem))
        print("PASS: calendar snapshot validation rejects stale edits, completion, deletion and duplicate binding")
        print("PASS: todo refinement rejects edited, completed, deleted groups and accepts unchanged snapshot")
        print("PASS: macOS old todo decoding, source groups, edit validation and persistence")
    }
}
