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

    /// 原文与整理稿都要检查：整理可能去掉口语触发词，也可能把
    /// 误识的触发词纠正回来。只有两者之一明确命中时才进入待办。
    static func shouldCreateTodo(rawText: String, cleanedText: String) -> Bool {
        looksLikeTodo(rawText) || looksLikeTodo(cleanedText)
    }

    /// 待办专用 prompt：把口述转成可直接执行的任务列表，而不是普通文章润色。
    /// 首次整理与 thinking 重新整理共用同一输出契约，避免两条路径格式漂移。
    /// 契约本身 2026-08-03 下沉到 `ShallWeTalkCore.TodoPrompt`，与 macOS 共用同一份，
    /// 消除此前"同一句口述在两端拆出不同待办"的分叉。
    static func todoFormattingPrompt(dictionary: [String] = []) -> String {
        TodoPrompt.formattingPrompt(dictionary: dictionary)
    }

    /// 兼容模型偶发加上的序号/项目符号，归一成真正的"一行一条"待办。
    static func parseTodoLines(_ text: String) -> [String] {
        TodoPrompt.parseLines(text)
    }

    /// 用小 LLM 调用把口述拆成简短待办条目;失败时降级为"去掉触发词的原文"单条
    ///
    /// `dictionary` 2026-08-03 补入:此前只有 Action 首次整理和待办「重新识别」两条
    /// 路径注入个人词典,普通口述走的这条不注入,同一个专名在待办里和正文里写法会不一致。
    /// 默认空数组,传空时 prompt 与补入前逐字相同。
    static func extractTodos(from text: String, llm: CleanupService,
                             dictionary: [String] = []) async -> [String] {
        do {
            let out = try await llm.clean(
                raw: text, systemPrompt: todoFormattingPrompt(dictionary: dictionary))
            let items = parseTodoLines(out)
            if !items.isEmpty { return items }
        } catch {}
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
