import XCTest
@testable import ShallWeTalkCore

final class UncertainSpansTests: XCTestCase {
    private func texts(_ spans: [UncertainSpans.Span], in displayed: String) -> [String] {
        let characters = Array(displayed)
        return spans.map { String(characters[$0.range]) }
    }

    func testNoSignalsWhenNothingChanged() {
        let spans = UncertainSpans.spans(
            displayed: "提醒我下周四做一个完整测试。",
            rawASR: "提醒我下周四做一个完整测试。")
        XCTAssertTrue(spans.isEmpty)
    }

    func testMarksWhereCleanupRewroteTheASRText() {
        // 整理模型把 ASR 的「一只」修成「一直」——正是需要用户扫一眼的位置。
        let displayed = "我一直觉得这个方案可行"
        let spans = UncertainSpans.spans(displayed: displayed, rawASR: "我一只觉得这个方案可行")
        XCTAssertEqual(texts(spans, in: displayed), ["直"])
        XCTAssertEqual(spans.map(\.reason), [.cleanupRewrote])
    }

    func testSpansNeverOverlapAndStayInOrder() {
        let displayed = "灵动岛在录音期间不显示待办信息"
        let spans = UncertainSpans.spans(displayed: displayed, rawASR: "灵动导在录音期间不显示代办讯息")
        for (a, b) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThan(a.range.upperBound, b.range.lowerBound)
        }
        for span in spans {
            XCTAssertLessThan(span.range.upperBound, displayed.count)
        }
    }

    func testGivesUpWhenCleanupReplacedEverything() {
        // 整段被改写(或 ASR 整段跑飞)时逐处标注没有意义,不该把整句都画上虚线。
        let spans = UncertainSpans.spans(displayed: "完全不同的一句话", rawASR: "毫无关联的另外内容")
        XCTAssertTrue(spans.isEmpty)
    }

    func testEmptyDisplayedTextProducesNoSpans() {
        XCTAssertTrue(UncertainSpans.spans(displayed: "", rawASR: "测试").isEmpty)
    }
}
