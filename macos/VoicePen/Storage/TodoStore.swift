import EventKit
import Foundation
import Combine

/// 闪念待办条目(Equatable:供 SwiftUI 列表按内容变化驱动动画)
struct TodoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var done: Bool
    var completedAt: Date?
    /// 产生该待办的口述历史 ID,用于共享原音文件。旧数据缺失时为 nil。
    var sourceRecordID: UUID? = nil
    /// ASR 原始文字,供“重新识别”的精细 prompt 重建待办。
    var sourceRawText: String? = nil
    /// 由本 App 自动创建的 iOS 日历事件，用于重新整理时更新而不重复创建。
    var calendarEventIdentifier: String? = nil
}

struct TodoGroupReplacement {
    let items: [TodoItem]
    let obsoleteCalendarEventIdentifiers: [String]
}

/// 待办存储:JSON 持久化,与历史同目录
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []

    private let file: URL
    @Published private(set) var persistenceError: String?
    private var loadBlocked = false
    private var dirty = false
    private var lastSnapshot: [UUID: TodoItem] = [:]
    private var changed: [UUID: TodoItem] = [:]
    private var deleted: Set<UUID> = []
    private var retryTimer: Timer?


    var pendingCount: Int { items.filter { !$0.done }.count }
    var pending: [TodoItem] { items.filter { !$0.done } }
    var completed: [TodoItem] { items.filter { $0.done } }

    init() {
        let base = AppDataDirectory.url()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("todos.json")
        load()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.dirty else { return }
            self.retryPersistence()
        }
        // 已完成超过 7 天的自动清理
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let before = items.count
        items.removeAll { $0.done && ($0.completedAt ?? .distantPast) < cutoff }
        if items.count != before { save() }
    }

    @discardableResult
    func add(_ texts: [String], sourceRecordID: UUID? = nil, sourceRawText: String? = nil) -> [TodoItem] {
        let new = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { TodoItem(id: UUID(), text: $0, createdAt: Date(), done: false, completedAt: nil,
                            sourceRecordID: sourceRecordID, sourceRawText: sourceRawText) }
        items.insert(contentsOf: new, at: 0)
        save()
        return new
    }

    /// 勾选完成时同时删掉对应的日历事项;取消完成时再把它建回来(2026-08-07 用户要求)。
    ///
    /// 为什么要成对做:只删不还的话,误点一次「完成」再取消,日程就悄悄没了,而用户不会
    /// 想到要去日历里补——这类静默的数据丢失比"没这个功能"更糟。`delete` 与
    /// `clearCompleted` 本来就已经在删日程,这里补齐的是 `toggle` 这一条漏掉的路径。
    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        items[i].completedAt = items[i].done ? Date() : nil
        let item = items[i]
        if item.done {
            let eventID = item.calendarEventIdentifier
            items[i].calendarEventIdentifier = nil   // 先断链再删,避免删失败时留下悬空 id
            save()
            if let eventID {
                Task { @MainActor in
                    await TodoCalendarScheduler.shared.remove(eventIdentifiers: [eventID])
                }
            }
        } else {
            save()
            restoreCalendarEvent(for: item)
        }
    }

    /// 取消完成后把日程建回来。
    ///
    /// 锚点必须用 `createdAt` 而不是"现在":待办文字里已经是「8月7号」这样的具体日期,
    /// `TodoDateResolver` 对未写年份的日期会按锚点判断该取今年还是明年——以当下为锚点,
    /// 一个已经过去的日期会被推到明年,建出一个错的日程。以创建时刻为锚点才能逐字重现
    /// 当初那次换算。解析不出日期(本来就没有日期的待办)则什么都不做。
    private func restoreCalendarEvent(for item: TodoItem) {
        guard item.calendarEventIdentifier == nil,
              let plan = TodoDateResolver.resolve(item.text, spokenAt: item.createdAt) else { return }
        Task { @MainActor [weak self] in
            _ = await TodoCalendarScheduler.shared.upsert(todo: item, plan: plan,
                isCurrent: { self?.isCurrentCalendarRequest(item) == true },
                didSave: { self?.setCalendarEventIdentifier($0, for: item.id) })
        }
    }

    /// Check after any calendar permission suspension, immediately before writing.
    func isCurrentCalendarRequest(_ snapshot: TodoItem) -> Bool {
        !snapshot.done && items.first(where: { $0.id == snapshot.id }) == snapshot
    }

    func delete(_ id: UUID) {
        let eventID = items.first(where: { $0.id == id })?.calendarEventIdentifier
        items.removeAll { $0.id == id }
        save()
        if let eventID {
            Task { @MainActor in await TodoCalendarScheduler.shared.remove(eventIdentifiers: [eventID]) }
        }
    }

    func restore(_ item: TodoItem) {
        items.insert(item, at: 0)
        save()
    }

    @discardableResult
    func updateText(_ id: UUID, text: String) -> TodoItem? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[i].text = value
        save()
        return items[i]
    }

    func setCalendarEventIdentifier(_ eventIdentifier: String, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].calendarEventIdentifier = eventIdentifier
        save()
    }

    /// 重新整理时以“一次录音”为单位整体替换。否则每个旧卡片都带着同一份
    /// sourceRawText，点任意一条都会把整段录音再塞回单卡，造成合并和重复。
    func recordingGroup(containing item: TodoItem) -> [TodoItem] {
        guard items.contains(where: { $0.id == item.id }) else { return [] }
        guard let sourceID = item.sourceRecordID else {
            return items.filter { $0.id == item.id }
        }
        return items.filter { $0.sourceRecordID == sourceID }
    }

    func replaceRecordingGroup(containing item: TodoItem, with texts: [String],
                               expectedGroup: [TodoItem]? = nil) -> TodoGroupReplacement? {
        if let expectedGroup {
            guard !expectedGroup.isEmpty,
                  recordingGroup(containing: item) == expectedGroup else { return nil }
        }
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        let matchingIndices: [Int]
        if let sourceID = item.sourceRecordID {
            matchingIndices = items.indices.filter { items[$0].sourceRecordID == sourceID }
        } else if let index = items.firstIndex(where: { $0.id == item.id }) {
            matchingIndices = [index]
        } else {
            return nil
        }
        guard let insertionIndex = matchingIndices.min() else { return nil }
        let existing = matchingIndices.map { items[$0] }
        let createdAt = existing.map(\.createdAt).min() ?? item.createdAt
        let allDone = existing.allSatisfy(\.done)
        let completedAt = allDone ? (existing.compactMap(\.completedAt).max() ?? Date()) : nil
        items.removeAll { candidate in
            if let sourceID = item.sourceRecordID { return candidate.sourceRecordID == sourceID }
            return candidate.id == item.id
        }
        let reusableEventIDs = existing.compactMap(\.calendarEventIdentifier)
        let replacements = cleaned.enumerated().map { index, text in
            TodoItem(id: UUID(), text: text, createdAt: createdAt, done: allDone,
                     completedAt: completedAt, sourceRecordID: item.sourceRecordID,
                     sourceRawText: item.sourceRawText,
                     calendarEventIdentifier: reusableEventIDs.indices.contains(index) ? reusableEventIDs[index] : nil)
        }
        items.insert(contentsOf: replacements, at: min(insertionIndex, items.count))
        save()
        return TodoGroupReplacement(
            items: replacements,
            obsoleteCalendarEventIdentifiers: Array(reusableEventIDs.dropFirst(replacements.count))
        )
    }

    /// 长按拖动到另一条上时,把 source 移到 target 之前。
    func move(_ sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let source = items.firstIndex(where: { $0.id == sourceID }),
              let target = items.firstIndex(where: { $0.id == targetID }) else { return }
        let item = items.remove(at: source)
        let adjustedTarget = source < target ? target - 1 : target
        items.insert(item, at: adjustedTarget)
        save()
    }

    func clearCompleted() {
        let eventIDs = items.filter(\.done).compactMap(\.calendarEventIdentifier)
        items.removeAll { $0.done }
        save()
        if !eventIDs.isEmpty {
            Task { @MainActor in await TodoCalendarScheduler.shared.remove(eventIdentifiers: eventIDs) }
        }
    }

    private func readItems() throws -> [TodoItem] {
        do { return try JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: file)) }
        catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) { return [] }
            throw error
        }
    }

    private func load() {
        do {
            items = try readItems()
            lastSnapshot = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            loadBlocked = true
            persistenceError = "待办暂时无法读取，原文件已保留"
        }
    }

    private func save() {
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, item) in current where lastSnapshot[id] != item { changed[id] = item; deleted.remove(id) }
        for id in lastSnapshot.keys where current[id] == nil { deleted.insert(id); changed.removeValue(forKey: id) }
        lastSnapshot = current
        dirty = true
        retryPersistence()
    }

    @discardableResult
    func retryPersistence() -> Bool {
        do {
            if loadBlocked {
                var restored = Dictionary(try readItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                restored.merge(changed, uniquingKeysWith: { _, current in current })
                for id in deleted { restored.removeValue(forKey: id) }
                items = restored.values.sorted { $0.createdAt > $1.createdAt }
                loadBlocked = false
            }
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
            lastSnapshot = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            changed = [:]; deleted = []; dirty = false; persistenceError = nil
            return true
        } catch {
            dirty = true
            persistenceError = "待办尚未保存，将重试：\(error.localizedDescription)"
            return false
        }
    }


}

/// 可依据“录音时间”重现的日期解析结果。
struct TodoCalendarPlan {
    let normalizedText: String
    let startDate: Date
    let isAllDay: Bool
}

/// 待办日期不交给 LLM 猜，由本地日历规则确定性换算。
enum TodoDateResolver {
    static func resolve(_ text: String, spokenAt: Date, calendar inputCalendar: Calendar = .autoupdatingCurrent) -> TodoCalendarPlan? {
        // Preserve an explicitly supplied calendar, including its time zone.
        let calendar = inputCalendar
        // 产品约定：凌晨 3 点换日。0:00–2:59 还属于用户的“前一天”。
        let semanticNow = calendar.date(byAdding: .hour, value: -3, to: spokenAt) ?? spokenAt
        let semanticDay = calendar.startOfDay(for: semanticNow)

        var targetDay: Date?
        var matchedRange: Range<String.Index>?

        // 先匹配最长相对词，避免“大后天”被截成“后天”。
        for (word, offset) in [("大后天", 3), ("后天", 2), ("明天", 1), ("今天", 0)] {
            if let range = text.range(of: word) {
                targetDay = calendar.date(byAdding: .day, value: offset, to: semanticDay)
                matchedRange = range
                break
            }
        }

        // 没有说“本/这/下”时，产品约定裸星期一律指本周。
        // 同时覆盖“周四 / 星期四 / 礼拜四”及其明确前缀；“下周”
        // 和“下下周”分别偏移 1 / 2 个自然周，不交给 NSDataDetector 猜。
        // 裸星期匹配排除“上周/每周”等前缀，避免把过去或重复日程误建成本周单次事件。
        let explicitWeekday = targetDay == nil
            ? firstMatch(#"((?:下下|这个|下个|本|这|下)(?:周|星期|礼拜))([一二三四五六日天1-7])"#, in: text)
            : nil
        let bareWeekday = targetDay == nil && explicitWeekday == nil
            ? firstMatch(#"(?<![上个每下本这])(周|星期|礼拜)([一二三四五六日天1-7])"#, in: text)
            : nil
        if targetDay == nil,
           let match = explicitWeekday ?? bareWeekday,
           let weekWord = substring(text, match.range(at: 1)),
           let weekdayWord = substring(text, match.range(at: 2)),
           let weekdayOffset = [
               "一": 0, "1": 0, "二": 1, "2": 1, "三": 2, "3": 2,
               "四": 3, "4": 3, "五": 4, "5": 4, "六": 5, "6": 5,
               "日": 6, "天": 6, "7": 6
           ][weekdayWord] {
            let systemWeekday = calendar.component(.weekday, from: semanticDay) // 1=周日
            let daysSinceMonday = (systemWeekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: semanticDay)!
            let extraWeek: Int
            if weekWord.hasPrefix("下下") {
                extraWeek = 14
            } else if weekWord.hasPrefix("下") {
                extraWeek = 7
            } else {
                extraWeek = 0
            }
            targetDay = calendar.date(byAdding: .day, value: extraWeek + weekdayOffset, to: monday)
            matchedRange = swiftRange(match.range, in: text)
        }

        // 已经是具体日期也需要创建日程。未说年份时，优先当年；已明显过去则取下一年。
        if targetDay == nil,
           let match = firstMatch(#"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)"#, in: text),
           let monthText = substring(text, match.range(at: 2)),
           let dayText = substring(text, match.range(at: 3)),
           let month = Int(monthText), let day = Int(dayText) {
            let explicitYear = substring(text, match.range(at: 1)).flatMap(Int.init)
            var year = explicitYear ?? calendar.component(.year, from: semanticDay)
            var components = DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day)
            if explicitYear == nil, let candidate = calendar.date(from: components), candidate < semanticDay {
                year += 1
                components.year = year
            }
            targetDay = calendar.date(from: components)
            matchedRange = swiftRange(match.range, in: text)
        }

        guard let targetDay, let matchedRange else { return nil }
        let concreteDate = "\(calendar.component(.month, from: targetDay))月\(calendar.component(.day, from: targetDay))号"
        var normalized = text
        normalized.replaceSubrange(matchedRange, with: concreteDate)

        let time = parseTime(in: text)
        let startDate: Date
        if let time {
            startDate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: targetDay) ?? targetDay
        } else {
            startDate = calendar.startOfDay(for: targetDay)
        }
        return TodoCalendarPlan(normalizedText: normalized, startDate: startDate, isAllDay: time == nil)
    }

    /// 中文数字小时/分钟(0–59)。口述出来的时间几乎都是"三点""两点半""十一点二十",
    /// 而此前 `parseTime` 只认阿拉伯数字,于是时间被整条丢掉、日历事件一律建成全天
    /// (2026-08-06 实测:"明天下午三点见李想" → 全天;写成"3点"才是 15:00)。
    /// 只覆盖时间语义需要的 0–59,不做通用中文数字解析。
    private static func chineseNumber(_ text: String) -> Int? {
        if let direct = Int(text) { return direct }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        guard let tenIndex = chars.firstIndex(of: "十") else {
            guard chars.count == 1, let value = digits[chars[0]] else { return nil }
            return value
        }
        let head = chars[..<tenIndex], tail = chars[(tenIndex + 1)...]
        let tens: Int
        if head.isEmpty { tens = 1 }                                        // 十一 = 11
        else if head.count == 1, let value = digits[head[head.startIndex]] { tens = value }
        else { return nil }
        let ones: Int
        if tail.isEmpty { ones = 0 }                                        // 二十 = 20
        else if tail.count == 1, let value = digits[tail[tail.startIndex]] { ones = value }
        else { return nil }
        return tens * 10 + ones
    }

    private static func parseTime(in text: String) -> (hour: Int, minute: Int)? {
        // 负向后顾排除"第三点"这类枚举序号被当成三点钟(只在本条已匹配到日期时才会走到这里,
        // 但"明天说一下第三点"这种同时带日期的句子确实存在)。
        let number = #"(?:\d{1,2}|[零〇一二两三四五六七八九十]{1,3})"#
        let pattern = "(凌晨|早上|上午|中午|下午|傍晚|晚上|夜里|深夜)?\\s*(?<!第)(\(number))(?:点|时|[:：])(?:(半)|(\(number))分?)?"
        guard let match = firstMatch(pattern, in: text),
              let hourText = substring(text, match.range(at: 2)),
              var hour = chineseNumber(hourText), (0...23).contains(hour) else { return nil }
        let period = substring(text, match.range(at: 1)) ?? ""
        let minute = substring(text, match.range(at: 3)) != nil
            ? 30
            : (substring(text, match.range(at: 4)).flatMap(chineseNumber) ?? 0)
        guard (0...59).contains(minute) else { return nil }
        if ["下午", "傍晚", "晚上", "夜里", "深夜"].contains(period), hour < 12 { hour += 12 }
        if period == "中午", hour < 11 { hour += 12 }
        if period == "凌晨", hour == 12 { hour = 0 }
        return (hour, minute)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let range = Range(range, in: text) else { return nil }
        return String(text[range])
    }

    private static func swiftRange(_ range: NSRange, in text: String) -> Range<String.Index>? {
        Range(range, in: text)
    }
}

@MainActor
final class TodoCalendarScheduler {
    static let shared = TodoCalendarScheduler()
    private let eventStore = EKEventStore()

    private init() {}

    /// 有 plan 时创建/移动日程；没有 plan 但 todo 已绑定日程时，只同步标题并保留原日期。
    /// 因此手动删掉文字里的日期不会让既有日程失联或被意外删除。
    func upsert(todo: TodoItem, plan: TodoCalendarPlan?,
                isCurrent: () -> Bool, didSave: (String) -> Void) async -> String? {
        guard await ensureAccess(), isCurrent() else { return nil }
        let existing = todo.calendarEventIdentifier.flatMap(eventStore.event(withIdentifier:))
        let event: EKEvent
        if let existing {
            event = existing
        } else {
            guard plan != nil, let calendar = eventStore.defaultCalendarForNewEvents else { return nil }
            event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
        }
        event.title = plan?.normalizedText ?? todo.text
        if let plan {
            event.startDate = plan.startDate
            event.isAllDay = plan.isAllDay
            event.endDate = plan.isAllDay
                ? Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: plan.startDate)!
                : plan.startDate.addingTimeInterval(60 * 60)
        }
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            // Bind before yielding the MainActor, so another queued update cannot
            // create a duplicate event while the saved identifier is still missing.
            if let identifier = event.eventIdentifier { didSave(identifier) }
            return event.eventIdentifier
        } catch {
            NSLog("Shall We Talk calendar write failed: %@", error.localizedDescription)
            return nil
        }
    }

    func remove(eventIdentifiers: [String]) async {
        guard !eventIdentifiers.isEmpty, await ensureAccess() else { return }
        for identifier in eventIdentifiers {
            guard let event = eventStore.event(withIdentifier: identifier) else { continue }
            try? eventStore.remove(event, span: .thisEvent, commit: false)
        }
        try? eventStore.commit()
    }

    private func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            do { return try await eventStore.requestFullAccessToEvents() }
            catch {
                NSLog("Shall We Talk calendar permission failed: %@", error.localizedDescription)
                return false
            }
        case .writeOnly:
            // 写入权限足够创建新事件，但不足以根据 identifier 更新；
            // 本 App 请求 full access，以便“重新整理”时不产生重复日程。
            return false
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }
}
