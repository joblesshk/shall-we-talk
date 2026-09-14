import Foundation
import ShallWeTalkCore

/// 闪念胶囊路由:判断口述是否是"对电脑提的请求"(而非要输入的正文)
/// 规则刻意保守且可预期:触发词必须出现在整理稿开头,普通口述零误伤、零额外延迟
enum IntentRouter {
    /// 触发词(开头匹配,允许前置标点/空白)
    private static let triggers = [
        "提醒我", "记一下", "记个", "记录一下", "帮我记", "别忘了", "待办",
        "加个待办", "添加待办", "加一条待办", "记得", "todo", "TODO",
    ]

    static func looksLikeTodo(_ text: String) -> Bool {
        let head = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",。:、!?,.:!? "))
        return triggers.contains { head.hasPrefix($0) }
    }

    static func shouldCreateTodo(rawText: String, cleanedText: String) -> Bool {
        looksLikeTodo(rawText) || looksLikeTodo(cleanedText)
    }

    /// 待办 prompt 与解析都来自 `ShallWeTalkCore.TodoPrompt`,与 iOS 共用同一份契约。
    /// (2026-08-03 之前这里是更早的内联文本,同一句口述两端会拆出不同条目。)
    static func todoFormattingPrompt(dictionary: [String] = []) -> String {
        TodoPrompt.formattingPrompt(dictionary: dictionary)
    }

    static func parseTodoLines(_ text: String) -> [String] {
        TodoPrompt.parseLines(text)
    }

    /// 用小 LLM 调用把口述拆成简短待办条目;失败时降级为"去掉触发词的原文"单条
    ///
    /// `dictionary` 2026-08-03 与 iOS 同步补入,默认空数组,传空时 prompt 与补入前逐字相同。
    static func extractTodos(from text: String, llm: CleanupService,
                             dictionary: [String] = []) async -> [String] {
        let response = await DictationPolicy.withTimeout {
            try? await llm.clean(raw: text, systemPrompt: todoFormattingPrompt(dictionary: dictionary))
        }
        if let response, let out = response {
            let items = parseTodoLines(out)
            if !items.isEmpty { return items }
        }
        // 降级:剥掉触发词,整句入待办,内容不丢
        var fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for t in triggers where fallback.hasPrefix(t) {
            fallback = String(fallback.dropFirst(t.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: ",。:、 "))
            break
        }
        return [fallback.isEmpty ? text : fallback]
    }
}
