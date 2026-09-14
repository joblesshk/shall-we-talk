import Foundation

/// 待办事项的输出契约(2026-08-03 下沉为两端共享)。
///
/// 此前 iOS 与 macOS 各有一份:iOS 已重构为带个人词典注入、首次提取与 thinking
/// 重新整理共用同一契约的版本;macOS 仍是更早的内联文本(“尽量不超过 20 字”、
/// 无词典、无全局日期补全),同一句口述在两端会被拆成不同的待办。这里按 iOS 版本
/// 统一,并把解析一并搬过来,让两端不可能再分叉。
///
/// 与 `PromptBuilder` 的分工:`PromptBuilder` 产出“把口述整理成正文”的 prompt,
/// 本文件产出“把口述整理成可执行条目”的 prompt,两者不共用规则,也不互相调用。
public enum TodoPrompt {
    /// 把 ASR 原文整理成可直接进待办清单的条目,而不是普通文章润色。
    /// 首次提取与 thinking 重新整理共用同一契约,避免两条路径格式漂移。
    public static func formattingPrompt(dictionary: [String] = []) -> String {
        var prompt = """
        你是口述待办事项整理器。请把 ASR 原文整理成简洁、可执行、可直接放进待办清单的条目。

        输出契约:
        - 说了几件事就输出几行，每行严格只有一件事。
        - 每行以明确动作为核心，例如“见……”“联系……”“提交……”；去掉“提醒我”“记一下”“其次”等口述套话。
        - 日期、时间、地点、人名、机构、数量、否定和条件必须保留；全局共享的日期/地点要补到每个相关条目中。
        - 后文的自我更正或总括说明优先。例如最后说“以上都在本周三”，则每条都应写“本周三”。
        - 不得丢失任何一件事，不得把后一件事重复包进前一行，不得虚构原文没有的内容。
        - 不加序号、项目符号、标题、解释或引号；只输出待办条目本身。
        """
        if !dictionary.isEmpty {
            prompt += "\n- 个人词典中的词必须采用以下写法：" + dictionary.joined(separator: "、")
        }
        return prompt
    }

    /// 兼容模型偶发加上的序号/项目符号，归一成真正的“一行一条”待办。
    public static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map {
                $0.replacingOccurrences(
                    // 序号后缀含全角变体(． 、 ）)。iOS 原实现在 raw string 里写成
                    // ．、） 交给 ICU 解析,这里直接写字面量,匹配集合等价,
                    // 由 TodoPromptTests 逐个后缀断言。
                    of: #"^\s*(?:[-•·*]|\d+[.．、)）])\s*"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }
}
