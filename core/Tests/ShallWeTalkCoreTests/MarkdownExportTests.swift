import XCTest
@testable import ShallWeTalkCore

/// Markdown 导出契约:段落结构、日期格式、可选 ASR 原文、待办分组、空历史与转义边界。
final class MarkdownExportTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    /// 2026-07-18 09:30 +0800
    private var sampleDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 18; c.hour = 9; c.minute = 30
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testEmptyHistoryAndNoTodosStillProducesValidDocument() {
        let doc = MarkdownExport.document(records: [], todos: [], timeZone: tz)
        XCTAssertEqual(doc, "# 记事\n\n_暂无记录_\n")
        XCTAssertFalse(doc.contains("# 待办"), "无待办时整节省略")
    }

    func testRecordSectionUsesHeadingDateFormatAndBody() {
        let doc = MarkdownExport.document(
            records: [.init(date: sampleDate, text: "整理后的正文。", rawText: "ASR 原始文字")],
            todos: [], timeZone: tz)
        XCTAssertTrue(doc.contains("## 2026-07-18 09:30\n\n整理后的正文。"))
        XCTAssertFalse(doc.contains("ASR 原始文字"), "默认不含 ASR 原文")
    }

    func testIncludeRawTextRendersQuoteBlock() {
        let doc = MarkdownExport.document(
            records: [.init(date: sampleDate, text: "正文", rawText: "原文第一行\n第二行")],
            todos: [], includeRawText: true, timeZone: tz)
        XCTAssertTrue(doc.contains("> ASR 原文:\n> 原文第一行\n> 第二行"))
    }

    func testTodosGroupedByCompletion() {
        let doc = MarkdownExport.document(
            records: [],
            todos: [.init(text: "买菜", done: false),
                    .init(text: "报税", done: true)],
            timeZone: tz)
        XCTAssertTrue(doc.contains("# 待办"))
        XCTAssertTrue(doc.contains("## 未完成\n\n- [ ] 买菜"))
        XCTAssertTrue(doc.contains("## 已完成\n\n- [x] 报税"))
    }

    func testLeadingHashInBodyIsEscaped() {
        // 口述内容行首出现 # 不能被解析成 Markdown 标题打乱导出层级
        let doc = MarkdownExport.document(
            records: [.init(date: sampleDate, text: "# 这不是标题\n正常第二行")],
            todos: [], timeZone: tz)
        XCTAssertTrue(doc.contains("\\# 这不是标题\n正常第二行"))
    }

    func testTodoNewlinesFlattenedToSingleLine() {
        let doc = MarkdownExport.document(
            records: [],
            todos: [.init(text: "第一件事\n还有补充", done: false)],
            timeZone: tz)
        XCTAssertTrue(doc.contains("- [ ] 第一件事 还有补充"))
    }

    func testSingleRecordMarkdownReusesSectionFormat() {
        let md = MarkdownExport.recordMarkdown(
            .init(date: sampleDate, text: "单条复制"), timeZone: tz)
        XCTAssertEqual(md, "## 2026-07-18 09:30\n\n单条复制")
    }

    func testDefaultFileName() {
        XCTAssertEqual(MarkdownExport.defaultFileName(date: sampleDate, timeZone: tz),
                       "ShallWeTalk-记事-20260718-0930.md")
    }
}
