import XCTest
@testable import ShallWeTalkCore

/// 会议转写拼接的核心不变式:跨段偏移必须反映真实墙钟间隔(中断期间的通话时长),
/// 不能靠简单累加各段音频时长——那样会把"打断了 8 分钟"悄悄吃掉。
final class MeetingTranscriptTests: XCTestCase {
    func testOffsetReflectsWallClockGapNotSummedSegmentDurations() {
        let meetingStart = Date(timeIntervalSince1970: 1_000_000)
        // 第一段:说了 30 秒
        let seg0 = MeetingSegment(
            index: 0, startedAt: meetingStart,
            endedAt: meetingStart.addingTimeInterval(30),
            utterances: [MeetingUtterance(text: "开场白", startMs: 0, endMs: 2000)],
            endReason: .interruption, isResolved: true)
        // 第二段:8 分钟后(一通电话)才恢复,新连接的 startMs 从 0 重新计
        let secondSegmentStart = meetingStart.addingTimeInterval(30 + 8 * 60)
        let seg1 = MeetingSegment(
            index: 1, startedAt: secondSegmentStart,
            endedAt: secondSegmentStart.addingTimeInterval(10),
            utterances: [MeetingUtterance(text: "我们继续", startMs: 500, endMs: 2000)],
            endReason: .manualStop, isResolved: true)

        let lines = MeetingTranscript.lines(segments: [seg0, seg1], meetingStartedAt: meetingStart)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].offsetMs, 0)
        // 期望:30_000ms(第一段时长) + 8*60_000ms(打断间隔) + 500ms(第二段内偏移)
        let expectedOffset = 30_000 + 8 * 60_000 + 500
        XCTAssertEqual(lines[1].offsetMs, expectedOffset)
        // 错误实现(累加段时长:30s + 500ms)会得到 30500,必须明确不是这个数
        XCTAssertNotEqual(lines[1].offsetMs, 30_500)
    }

    func testOutOfOrderUtterancesWithinSegmentAreSorted() {
        let start = Date()
        let seg = MeetingSegment(index: 0, startedAt: start, utterances: [
            MeetingUtterance(text: "后说的", startMs: 5000, endMs: 6000),
            MeetingUtterance(text: "先说的", startMs: 100, endMs: 900),
        ])
        let lines = MeetingTranscript.lines(segments: [seg], meetingStartedAt: start)
        XCTAssertEqual(lines.map(\.text), ["先说的", "后说的"])
    }

    func testBoundaryMarkerPerReason() {
        XCTAssertEqual(MeetingTranscript.boundaryMarker(for: .interruption, resumedAtOffsetMs: 65_000),
                       "— 通话打断，01:05 恢复 —")
        XCTAssertEqual(MeetingTranscript.boundaryMarker(for: .routeChange, resumedAtOffsetMs: 5_000),
                       "— 音频设备切换，00:05 恢复 —")
        XCTAssertEqual(MeetingTranscript.boundaryMarker(for: .appTerminated, resumedAtOffsetMs: 0),
                       "— 录音中断，此处可能有缺失 —")
        XCTAssertNil(MeetingTranscript.boundaryMarker(for: .rotation, resumedAtOffsetMs: 0))
        XCTAssertNil(MeetingTranscript.boundaryMarker(for: .manualStop, resumedAtOffsetMs: 0))
    }

    func testSpeakerLabelsNumberByFirstAppearanceAndNilRendersUnlabeled() {
        let start = Date()
        let seg = MeetingSegment(index: 0, startedAt: start, utterances: [
            MeetingUtterance(text: "A1", startMs: 0, endMs: 100, speakerID: "7"),
            MeetingUtterance(text: "B1", startMs: 200, endMs: 300, speakerID: "3"),
            MeetingUtterance(text: "unlabeled", startMs: 400, endMs: 500, speakerID: nil),
            MeetingUtterance(text: "A2", startMs: 600, endMs: 700, speakerID: "7"),
        ])
        let lines = MeetingTranscript.lines(segments: [seg], meetingStartedAt: start)
        XCTAssertEqual(lines.map(\.speakerLabel), ["说话人 1", "说话人 2", "未标注", "说话人 1"])
    }

    func testPromptTextIncludesBoundaryMarkers() {
        let start = Date()
        let seg0 = MeetingSegment(index: 0, startedAt: start,
                                  endedAt: start.addingTimeInterval(5),
                                  utterances: [MeetingUtterance(text: "第一段", startMs: 0, endMs: 1000)],
                                  endReason: .interruption)
        let seg1 = MeetingSegment(index: 1, startedAt: start.addingTimeInterval(65),
                                  utterances: [MeetingUtterance(text: "第二段", startMs: 0, endMs: 1000)],
                                  endReason: .manualStop)
        let text = MeetingTranscript.promptText(segments: [seg0, seg1], meetingStartedAt: start)
        XCTAssertTrue(text.contains("通话打断"))
        XCTAssertTrue(text.contains("第一段"))
        XCTAssertTrue(text.contains("第二段"))
    }

    func testRotationProducesNoVisibleBoundaryInDisplayText() {
        let start = Date()
        let seg0 = MeetingSegment(index: 0, startedAt: start,
                                  endedAt: start.addingTimeInterval(1200),
                                  utterances: [MeetingUtterance(text: "上半段", startMs: 0, endMs: 1000)],
                                  endReason: .rotation)
        let seg1 = MeetingSegment(index: 1, startedAt: start.addingTimeInterval(1200),
                                  utterances: [MeetingUtterance(text: "下半段", startMs: 0, endMs: 1000)],
                                  endReason: .manualStop)
        let text = MeetingTranscript.displayText(segments: [seg0, seg1], meetingStartedAt: start)
        XCTAssertFalse(text.contains("—"))
    }
}
