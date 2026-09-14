import XCTest
@testable import ShallWeTalkCore

final class VolcStreamingDiagnosticsTests: XCTestCase {
    private func response(flags: UInt8 = 0, sequence: Int32? = nil, json: String = "{}",
                          compressed: Bool = false) -> Data {
        var data = Data([0x11, (0b1001 << 4) | flags, compressed ? 0x11 : 0x10, 0])
        if let sequence { var value = sequence.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(json.data(using: .utf8)!)
        return data
    }

    func testResultFrameClassificationCoversTextAndUtterancesWithoutRetainingText() {
        let parsed = VolcResultFrameParse.parse(response(flags: 0x03, sequence: 7,
            json: #"{"result":{"text":"spoken","utterances":[{"text":"spoken","definite":true}]}}"#))
        guard case .result(let sequence, let flags, let body, _) = parsed else {
            return XCTFail("expected result frame")
        }
        XCTAssertEqual(sequence, 7)
        XCTAssertEqual(flags, 0x03)
        let object = try! XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(object["result"])
    }

    func testResultFrameBodyOffsetWorksWithAndWithoutSequence() throws {
        for frame in [response(json: #"{"result":{"text":"x"}}"#),
                      response(flags: 0x01, sequence: 12, json: #"{"result":{"text":"x"}}"#)] {
            guard case .result(_, _, let body, _) = VolcResultFrameParse.parse(frame) else {
                return XCTFail("expected result frame")
            }
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    func testUtteranceSignalsRequireNonEmptyStringText() {
        let empty = VolcUtteranceSignals.from([["text": ""]])
        XCTAssertTrue(empty.present)
        XCTAssertFalse(empty.hasNonEmptyText)
        XCTAssertFalse(empty.hasDefiniteNonEmptyText)
        let onlyUtterance = VolcUtteranceSignals.from([["text": "spoken", "definite": true]])
        XCTAssertTrue(onlyUtterance.hasNonEmptyText)
        XCTAssertTrue(onlyUtterance.hasDefiniteNonEmptyText)
    }

    func testSequenceObservationCountsNonAdjacentDuplicates() {
        var state = VolcSequenceObservation()
        state.observe(1); state.observe(2); state.observe(1); state.observe(3); state.observe(2)
        XCTAssertEqual(state.duplicateCount, 2)
        XCTAssertTrue(state.monotonicityBroken)
        state.observe(0)
        XCTAssertTrue(state.monotonicityBroken)
    }

    func testMalformedJSONAndGzipFailureAreClassified() {
        guard case .resultJSONFailed = VolcResultFrameParse.parse(response(json: "not-json")) else {
            return XCTFail("expected JSON failure")
        }
        guard case .resultDecompressionFailed = VolcResultFrameParse.parse(response(compressed: true)) else {
            return XCTFail("expected decompression failure")
        }
    }

    func testShortOtherAndMissingResultDoNotBecomeText() {
        guard case .shortOrInvalid = VolcResultFrameParse.parse(Data([0x11, 0x91])) else { return XCTFail() }
        guard case .otherMessageType = VolcResultFrameParse.parse(Data([0x11, 0x21, 0x10, 0])) else { return XCTFail() }
        guard case .result = VolcResultFrameParse.parse(response(json: #"{"meta":{}}"#)) else { return XCTFail() }
    }

    func testDiagnosticsDefaultsAreZeroAndOptional() {
        let value = VolcStreamingDiagnostics(requestID: "r", connectID: "c", configurationSent: true,
            audioBytesSent: 1, audioPacketCount: 1, resultFrameCount: 2, receivedFinalResult: true,
            firstPartialMillis: 4, lastErrorDescription: nil, configurationSentMillis: 1,
            firstAudioSentMillis: 2, lastAudioSentMillis: 3, finishRequestedMillis: 4,
            endFrameSentMillis: 5, endFrameSequence: -2, firstResultFrameMillis: 6,
            finalResultMillis: 7, topLevelNonEmptyTextFrameCount: 1,
            finalFrameHadNonEmptyTopLevelText: true, onPartialInvocationCount: 1)
        XCTAssertEqual(value.topLevelNonEmptyTextFrameCount, 1)
        XCTAssertEqual(value.parseableResultJSONFrameCount, 0)
        XCTAssertNil(value.firstFinalFrameMillis)
    }
}
