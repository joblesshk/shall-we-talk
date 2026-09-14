import XCTest
@testable import ShallWeTalkCore

final class MeetingSummaryPromptTests: XCTestCase {
    private let sampleJSON = """
    {"title": "Q3 投后管理会议", "oneLine": "讨论 Q3 业绩与下一轮融资节奏",
     "timeline": [{"at": "01:30", "topic": "业绩回顾", "detail": "收入同比增长 20%"}],
     "keyPoints": ["收入增长符合预期"],
     "decisions": [{"text": "下周提交董事会材料", "status": "已确认"}],
     "actionItems": [{"task": "准备财务模型", "owner": "CFO", "deadline": "下周五"}],
     "openQuestions": ["下一轮估值区间尚未讨论"]}
    """

    func testParsesBareJSON() {
        let summary = MeetingSummaryParser.parse(sampleJSON)
        XCTAssertEqual(summary?.title, "Q3 投后管理会议")
        XCTAssertEqual(summary?.timeline.first?.at, "01:30")
    }

    func testParsesFencedJSON() {
        let fenced = "```json\n\(sampleJSON)\n```"
        let summary = MeetingSummaryParser.parse(fenced)
        XCTAssertEqual(summary?.title, "Q3 投后管理会议")
    }

    func testParsesJSONWithLeadingProse() {
        let withProse = "好的,这是会议纪要：\n\n\(sampleJSON)"
        let summary = MeetingSummaryParser.parse(withProse)
        XCTAssertEqual(summary?.title, "Q3 投后管理会议")
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(MeetingSummaryParser.parse("这不是 JSON,模型偷懒了。"))
        XCTAssertNil(MeetingSummaryParser.parse("{\"title\": \"缺少右括号\""))
    }

    func testEmptyTitleReturnsNil() {
        let json = """
        {"title": "", "oneLine": "x", "timeline": [], "keyPoints": [], "decisions": [], "actionItems": [], "openQuestions": []}
        """
        XCTAssertNil(MeetingSummaryParser.parse(json))
    }

    func testMalformedTimelineRowsAreDroppedNotFatal() {
        let json = """
        {"title": "会议", "oneLine": "x",
         "timeline": [{"at": "1:05", "topic": "ok", "detail": "d"},
                      {"at": "不是时间", "topic": "bad", "detail": "d"},
                      {"at": "12:34", "topic": "ok2", "detail": "d"}],
         "keyPoints": [], "decisions": [], "actionItems": [], "openQuestions": []}
        """
        let summary = MeetingSummaryParser.parse(json)
        XCTAssertEqual(summary?.timeline.map(\.topic), ["ok", "ok2"])
    }

    func testActionItemOwnerAndDeadlineAreNilWhenNotStated() {
        let json = """
        {"title": "会议", "oneLine": "x", "timeline": [], "keyPoints": [],
         "decisions": [], "actionItems": [{"task": "跟进合同条款", "owner": null, "deadline": null}],
         "openQuestions": []}
        """
        let summary = MeetingSummaryParser.parse(json)
        XCTAssertEqual(summary?.actionItems.first?.task, "跟进合同条款")
        XCTAssertNil(summary?.actionItems.first?.owner)
        XCTAssertNil(summary?.actionItems.first?.deadline)
    }

    func testDecisionStatusRoundTrips() {
        let summary = MeetingSummaryParser.parse(sampleJSON)
        XCTAssertEqual(summary?.decisions.first?.status, "已确认")
    }

    func testChunkingNeverSplitsMidUtteranceAndPreservesTimestamp() {
        let lines = (0..<200).map { "[\(String(format: "%02d:%02d", $0 / 60, $0 % 60))] 说话人 1：这是第 \($0) 句话内容填充填充。" }
        let text = lines.joined(separator: "\n")
        let chunks = MeetingSummaryPromptBuilder.chunkPromptText(text, maxChars: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        // 每个 chunk 都由完整的行组成:拼回去应与原文一致(无字符丢失/错位)
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasPrefix("["), "分块不应从半句话开始: \(chunk.prefix(20))")
        }
    }

    func testShortTranscriptSkipsChunking() {
        let short = "[00:01] 说话人 1：很短的一句话。"
        XCTAssertEqual(MeetingSummaryPromptBuilder.chunkPromptText(short, maxChars: 6000), [short])
    }
}
