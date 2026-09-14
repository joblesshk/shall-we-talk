import Foundation
import ShallWeTalkCore

extension AppState {
    func refineTodo(_ item: TodoItem) async throws {
        let expectedGroup = todos.recordingGroup(containing: item)
        guard expectedGroup.contains(item) else {
            throw NSError(domain: "Todo", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "待办已变更，请重新发起整理。"])
        }
        try await settings.prepareRelaySession()
        let source = (item.sourceRawText ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                 apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
        let refined = try await llm.clean(raw: source,
            systemPrompt: IntentRouter.todoFormattingPrompt(dictionary: settings.dictionaryWords), thinking: .enabled)
        let lines = IntentRouter.parseTodoLines(refined)
        guard !lines.isEmpty else {
            throw NSError(domain: "Todo", code: 3, userInfo: [NSLocalizedDescriptionKey: "重新整理未生成待办事项，原内容已保留。"])
        }
        let spokenAt = item.sourceRecordID
            .flatMap { id in history.records.first(where: { $0.id == id })?.date } ?? item.createdAt
        let plans = lines.map { TodoDateResolver.resolve($0, spokenAt: spokenAt) }
        let normalized = zip(lines, plans).map { text, plan in plan?.normalizedText ?? text }
        guard let replacement = todos.replaceRecordingGroup(containing: item, with: normalized,
                                                              expectedGroup: expectedGroup) else {
            throw NSError(domain: "Todo", code: 4, userInfo: [NSLocalizedDescriptionKey: "待办已变更，未覆盖现有内容。"])
        }
        enqueueCalendarUpdates(todos: replacement.items, plans: plans,
                               obsoleteEventIdentifiers: replacement.obsoleteCalendarEventIdentifiers)
    }

    func updateTodoText(_ id: UUID, text: String) {
        let plan = TodoDateResolver.resolve(text, spokenAt: Date())
        guard let updated = todos.updateText(id, text: plan?.normalizedText ?? text) else { return }
        enqueueCalendarUpdates(todos: [updated], plans: [plan])
    }

    func enqueueCalendarUpdates(todos scheduledTodos: [TodoItem], plans: [TodoCalendarPlan?],
                                obsoleteEventIdentifiers: [String] = []) {
        guard plans.contains(where: { $0 != nil })
                || scheduledTodos.contains(where: { $0.calendarEventIdentifier != nil })
                || !obsoleteEventIdentifiers.isEmpty else { return }
        Task { @MainActor [weak self] in
            await TodoCalendarScheduler.shared.remove(eventIdentifiers: obsoleteEventIdentifiers)
            for (todo, plan) in zip(scheduledTodos, plans) {
                guard !todo.done, plan != nil || todo.calendarEventIdentifier != nil else { continue }
                _ = await TodoCalendarScheduler.shared.upsert(todo: todo, plan: plan,
                    isCurrent: { self?.todos.isCurrentCalendarRequest(todo) == true },
                    didSave: { self?.todos.setCalendarEventIdentifier($0, for: todo.id) })
            }
        }
    }
}
