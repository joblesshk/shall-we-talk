import Foundation

/// 记事 → Markdown 导出(纯函数,iOS/macOS 两端共用;输入记录数组 → String)。
/// 格式约定:
/// - 每条记录一段:`## yyyy-MM-dd HH:mm` 标题 + 正文(整理后文本);
///   可选附 ASR 原文(引用块,默认不含);
/// - 待办单独一节,未完成/已完成分组,GFM 任务列表(`- [ ]` / `- [x]`);
/// - 正文行首的 `#` 转义为 `\#`,防止口述内容被解析成标题;待办条目内换行压成空格。
/// 存储层不进本包:两端各自把 DictationRecord/TodoItem 映射为下面的最小字段结构。
public enum MarkdownExport {
    /// 导出所需的最小记录字段
    public struct Record {
        public let date: Date
        public let text: String      // 展示文本:finalText ?? cleanText
        public let rawText: String   // ASR 原文(includeRawText 时输出)

        public init(date: Date, text: String, rawText: String = "") {
            self.date = date
            self.text = text
            self.rawText = rawText
        }
    }

    /// 导出所需的最小待办字段
    public struct Todo {
        public let text: String
        public let done: Bool

        public init(text: String, done: Bool) {
            self.text = text
            self.done = done
        }
    }

    /// 整份导出文档:记录一节(空历史时给占位说明)+ 待办一节(无待办时整节省略)。
    public static func document(records: [Record],
                                todos: [Todo],
                                includeRawText: Bool = false,
                                timeZone: TimeZone = .current) -> String {
        let formatter = headingFormatter(timeZone: timeZone)
        var sections: [String] = ["# 记事"]
        if records.isEmpty {
            sections.append("_暂无记录_")
        } else {
            sections.append(contentsOf: records.map {
                recordSection($0, includeRawText: includeRawText, formatter: formatter)
            })
        }

        if !todos.isEmpty {
            sections.append("# 待办")
            let pending = todos.filter { !$0.done }
            let done = todos.filter { $0.done }
            if !pending.isEmpty {
                sections.append("## 未完成\n\n" + pending.map { "- [ ] \(todoLine($0.text))" }.joined(separator: "\n"))
            }
            if !done.isEmpty {
                sections.append("## 已完成\n\n" + done.map { "- [x] \(todoLine($0.text))" }.joined(separator: "\n"))
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// 单条记录的 Markdown(「复制为 Markdown」复用同一段落生成逻辑)。
    public static func recordMarkdown(_ record: Record,
                                      includeRawText: Bool = false,
                                      timeZone: TimeZone = .current) -> String {
        recordSection(record, includeRawText: includeRawText, formatter: headingFormatter(timeZone: timeZone))
    }

    /// 双端一致的默认导出文件名,如 `ShallWeTalk-记事-20260718-0930.md`。
    public static func defaultFileName(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "ShallWeTalk-记事-\(f.string(from: date)).md"
    }

    // MARK: - 私有

    private static func recordSection(_ record: Record,
                                      includeRawText: Bool,
                                      formatter: DateFormatter) -> String {
        var lines = "## \(formatter.string(from: record.date))\n\n\(escapeBody(record.text))"
        if includeRawText, !record.rawText.isEmpty {
            let quoted = record.rawText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            lines += "\n\n> ASR 原文:\n\(quoted)"
        }
        return lines
    }

    private static func headingFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }

    /// 正文只做最小转义:行首 `#` 加反斜杠,避免口述内容被 Markdown 解析成标题、
    /// 打乱导出文档的层级;其余内容原样保留(导出以保真为先)。
    private static func escapeBody(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.first == "#" ? "\\\(line)" : String(line)
            }
            .joined(separator: "\n")
    }

    /// 待办是列表条目:内部换行压成空格,保持一条待办一行。
    private static func todoLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
