import XCTest
@testable import ShallWeTalkCore

/// 待办契约 2026-08-03 下沉为两端共享。此前 macOS 用的是更早的内联文本
/// (“尽量不超过 20 字”、无个人词典、无全局日期补全),同一句口述在两端会拆出
/// 不同的待办条目。这些断言锁住 iOS 版契约,防止任一端再私自内联一份。
final class TodoPromptTests: XCTestCase {
    func testFormattingPromptKeepsTheExecutableItemContract() {
        let prompt = TodoPrompt.formattingPrompt()
        XCTAssertTrue(prompt.contains("说了几件事就输出几行，每行严格只有一件事"))
        XCTAssertTrue(prompt.contains("每行以明确动作为核心"))
        XCTAssertTrue(prompt.contains("全局共享的日期/地点要补到每个相关条目中"))
        XCTAssertTrue(prompt.contains("后文的自我更正或总括说明优先"))
        XCTAssertTrue(prompt.contains("不加序号、项目符号、标题、解释或引号"))
        // 旧 macOS 版的字数上限会把长条目截短,不得回归。
        XCTAssertFalse(prompt.contains("尽量不超过 20 字"),
                       "the pre-2026-08-03 macOS length cap must not come back")
    }

    func testDictionaryIsInjectedOnlyWhenPresent() {
        XCTAssertFalse(TodoPrompt.formattingPrompt().contains("个人词典"))
        let withDict = TodoPrompt.formattingPrompt(dictionary: ["Keychain", "BVI"])
        XCTAssertTrue(withDict.contains("个人词典中的词必须采用以下写法：Keychain、BVI"))
    }

    /// 词典注入不得改动契约本体:空词典时必须与不传参逐字相同,非空时只在末尾追加一行,
    /// 前缀完全不变。这样给 `extractTodos` 补上词典不会牵动既有的待办输出格式。
    func testDictionaryOnlyAppendsAndNeverRewritesTheContract() {
        let base = TodoPrompt.formattingPrompt()
        XCTAssertEqual(TodoPrompt.formattingPrompt(dictionary: []), base,
                       "an empty dictionary must be byte-identical to omitting it")
        let withDict = TodoPrompt.formattingPrompt(dictionary: ["Keychain"])
        XCTAssertTrue(withDict.hasPrefix(base), "the dictionary line must be appended, not woven in")
        XCTAssertEqual(withDict.dropFirst(base.count),
                       "\n- 个人词典中的词必须采用以下写法：Keychain")
    }

    func testParseLinesStripsEveryBulletAndOrdinalMarker() {
        let raw = """
        - 下午把合同发给对方
        1. 晚上确认打款时间
        2．联系律师
        3、准备董事会材料
        4)预约体检
        5）取快递
        • 交电费
        · 还书
        * 买咖啡豆
        """
        XCTAssertEqual(TodoPrompt.parseLines(raw), [
            "下午把合同发给对方", "晚上确认打款时间", "联系律师", "准备董事会材料",
            "预约体检", "取快递", "交电费", "还书", "买咖啡豆",
        ])
    }

    func testParseLinesDropsBlankLinesAndKeepsInnerPunctuation() {
        let raw = "\n  1. 见张总，谈 A 轮  \n\n\n2. 提交 10-K 草稿\n   \n"
        XCTAssertEqual(TodoPrompt.parseLines(raw), ["见张总，谈 A 轮", "提交 10-K 草稿"])
    }

    func testParseLinesDoesNotEatContentThatMerelyStartsWithADigit() {
        // "2026 年" 不是序号前缀,不能被剥掉。
        XCTAssertEqual(TodoPrompt.parseLines("2026 年底前完成迁移"), ["2026 年底前完成迁移"])
    }
}
