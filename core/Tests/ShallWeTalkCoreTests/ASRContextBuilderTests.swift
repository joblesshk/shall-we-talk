import XCTest
@testable import ShallWeTalkCore

final class ASRContextBuilderTests: XCTestCase {
    private struct StubRecord: RecentTextRecord {
        var date: Date
        var finalText: String?
        var cleanText: String
    }

    func testExcludesRecordsOlderThanLookbackWindow() {
        let now = Date()
        let recent = StubRecord(date: now.addingTimeInterval(-60), finalText: nil, cleanText: "最近说的话")
        let old = StubRecord(date: now.addingTimeInterval(-30 * 60), finalText: nil, cleanText: "半小时前说的话")
        let data = ASRContextBuilder.contextData(records: [old, recent], now: now)
        XCTAssertEqual(data, [["text": "最近说的话"]])
    }

    func testOrdersNewestFirstRegardlessOfInputOrder() {
        let now = Date()
        let older = StubRecord(date: now.addingTimeInterval(-600), finalText: nil, cleanText: "较早")
        let newer = StubRecord(date: now.addingTimeInterval(-60), finalText: nil, cleanText: "较新")
        let data = ASRContextBuilder.contextData(records: [older, newer], now: now)
        XCTAssertEqual(data, [["text": "较新"], ["text": "较早"]])
    }

    func testPrefersFinalTextOverCleanTextWhenEdited() {
        let now = Date()
        let record = StubRecord(date: now.addingTimeInterval(-60), finalText: "改过的最终稿", cleanText: "整理稿原文")
        let data = ASRContextBuilder.contextData(records: [record], now: now)
        XCTAssertEqual(data, [["text": "改过的最终稿"]])
    }

    func testDropsOldestFirstWhenCharBudgetExceeded() {
        let now = Date()
        let big = String(repeating: "字", count: ASRContextBuilder.tokenBudgetChars)
        let older = StubRecord(date: now.addingTimeInterval(-300), finalText: nil, cleanText: "这段应该被挤掉")
        let newer = StubRecord(date: now.addingTimeInterval(-60), finalText: nil, cleanText: big)
        let data = ASRContextBuilder.contextData(records: [older, newer], now: now)
        XCTAssertEqual(data, [["text": big]], "预算耗尽后应该舍弃更旧的一条,只保留最新的")
    }

    func testCapsAtMaxTurnsEvenWithinBudget() {
        let now = Date()
        let records = (0..<30).map { i in
            StubRecord(date: now.addingTimeInterval(-Double(i) * 10), finalText: nil, cleanText: "x")
        }
        let data = ASRContextBuilder.contextData(records: records, now: now)
        XCTAssertEqual(data.count, ASRContextBuilder.maxTurns)
    }

    func testEmptyWhenNoRecordsInWindow() {
        let now = Date()
        let old = StubRecord(date: now.addingTimeInterval(-3600), finalText: nil, cleanText: "很久以前")
        XCTAssertTrue(ASRContextBuilder.contextData(records: [old], now: now).isEmpty)
    }
}
