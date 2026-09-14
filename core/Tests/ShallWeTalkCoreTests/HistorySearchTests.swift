import XCTest
@testable import ShallWeTalkCore

/// 记事全文搜索过滤契约:大小写不敏感、中文子串、多关键词 AND、空查询直通。
final class HistorySearchTests: XCTestCase {
    func testEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertEqual(HistorySearch.keywords(from: ""), [])
        XCTAssertEqual(HistorySearch.keywords(from: "   \n\t"), [])
        XCTAssertTrue(HistorySearch.matches(fields: ["任意内容"], keywords: []))
        XCTAssertTrue(HistorySearch.matches(fields: [], keywords: []))
    }

    func testCaseInsensitiveEnglishMatch() {
        let keywords = HistorySearch.keywords(from: "SHALL talk")
        XCTAssertEqual(keywords, ["shall", "talk"])
        XCTAssertTrue(HistorySearch.matches(fields: ["用 Shall We Talk 口述"], keywords: keywords))
    }

    func testChineseSubstringMatch() {
        let keywords = HistorySearch.keywords(from: "做多")
        XCTAssertTrue(HistorySearch.matches(fields: ["我是一直做多的呀"], keywords: keywords))
        XCTAssertFalse(HistorySearch.matches(fields: ["我是一直看空的呀"], keywords: keywords))
    }

    func testMultiKeywordRequiresAllToHit() {
        let keywords = HistorySearch.keywords(from: "会议 周四")
        XCTAssertTrue(HistorySearch.matches(fields: ["周四下午的会议纪要"], keywords: keywords))
        XCTAssertFalse(HistorySearch.matches(fields: ["周四下午的散步"], keywords: keywords),
                       "缺一个关键词就不算命中(AND 语义)")
    }

    func testKeywordsMayHitDifferentFields() {
        // 关键词允许分别命中不同字段(整理稿命中一个、ASR 原文命中另一个)
        let keywords = HistorySearch.keywords(from: "基金 谷歌")
        XCTAssertTrue(HistorySearch.matches(fields: ["一只做多的基金", "谷歌我是一只做多的"], keywords: keywords))
        XCTAssertFalse(HistorySearch.matches(fields: ["一只做多的基金", "没有提到那家公司"], keywords: keywords))
    }
}
