import XCTest
@testable import ShallWeTalkCore

/// 插入边界感知。跑在保真链路最后一步,所以这里既要证明"该改的改了",
/// 也要证明"不该改的一个字都没动"。
final class InsertionBoundaryTests: XCTestCase {
    func testAddsSpaceBetweenAsciiWords() {
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "roughly 30x earnings",
                                     before: "The valuation is", after: nil),
            " roughly 30x earnings")
        // 数字同样算词字符:`build 145` 后面接 `145` 不能粘成 `145145`。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "145 已安装", before: "build", after: nil),
            " 145 已安装")
    }

    func testDoesNotAddSpaceWhenEitherSideIsNotAsciiWord() {
        // 中英之间不补空格:排版偏好,不是正确性问题,系统输入法同样不补。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "valuation 的问题", before: "我们讨论了", after: nil),
            "valuation 的问题")
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "昨天的会议", before: "Goldman", after: nil),
            "昨天的会议")
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行", before: "我们讨论了", after: nil),
            "这个方案可行")
    }

    func testDoesNotDoubleSpaceWhenBeforeAlreadyEndsWithWhitespace() {
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "roughly 30x", before: "The valuation is ", after: nil),
            "roughly 30x")
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "roughly 30x", before: "confirmed\n", after: nil),
            "roughly 30x")
    }

    func testNilBeforeContextNeverAddsSpace() {
        // 上下文取不到时宁可不加:未知上下文里凭空插空格是不可撤销的污染。
        XCTAssertEqual(InsertionBoundary.adjust(text: "roughly 30x", before: nil, after: nil),
                       "roughly 30x")
    }

    func testDropsDuplicateSentenceEndingPunctuation() {
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行。", before: "我认为", after: "。"),
            "这个方案可行")
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "还有别的选择吗？", before: "", after: "？后面还有字"),
            "还有别的选择吗")
    }

    func testKeepsPunctuationWhenItDoesNotActuallyRepeat() {
        // 句末标点不同就不是重复,不得擅自删。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行。", before: "我认为", after: "？"),
            "这个方案可行。")
        // 逗号不在 sentenceEnds 里,不参与去重。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行，", before: "我认为", after: "，"),
            "这个方案可行，")
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行。", before: "我认为", after: nil),
            "这个方案可行。")
    }

    func testCapitalizesOnlyAtFieldStartAndOnlyWhenHostAsksForIt() {
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "the meeting is confirmed", before: "", after: nil,
                                     capitalizeSentenceStart: true),
            "The meeting is confirmed")
        // 宿主没声明句首大写 → 一个字都不动。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "the meeting is confirmed", before: "", after: nil),
            "the meeting is confirmed")
        // 不在输入框开头 → 不动。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "the meeting is confirmed", before: "Yesterday ", after: nil,
                                     capitalizeSentenceStart: true),
            "the meeting is confirmed")
        // 中文与非 ASCII 首字符不受影响。
        XCTAssertEqual(
            InsertionBoundary.adjust(text: "这个方案可行", before: "", after: nil,
                                     capitalizeSentenceStart: true),
            "这个方案可行")
    }

    func testEmptyTextIsReturnedUnchanged() {
        XCTAssertEqual(InsertionBoundary.adjust(text: "", before: "The valuation is", after: "。"), "")
    }

    func testTypicalChineseDictationIsUntouched() {
        // 主场景回归:纯中文追加口述,插入前后必须逐字一致。
        let text = "我们下周再谈这个方案的估值区间。"
        XCTAssertEqual(
            InsertionBoundary.adjust(text: text, before: "关于昨天那件事，", after: "",
                                     capitalizeSentenceStart: true),
            text)
    }
}
