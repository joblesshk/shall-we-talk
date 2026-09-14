import XCTest
@testable import ShallWeTalkCore

final class VolcFileTranscriptionRequestConfigTests: XCTestCase {
    func testMeetingFileRequestUsesFaithfulMeetingConfiguration() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46])
        let payload = VolcFileTranscription.makeRequestPayload(
            wav: wav, enableSpeakerInfo: true,
            hotwordsContext: #"{"hotwords":[{"word":"VoicePen"}]}"#,
            outputChineseVariant: "simplified")

        XCTAssertEqual(payload["language"] as? String, "zh-CN")
        let audio = try XCTUnwrap(payload["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(audio["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual(audio["rate"] as? Int, 16_000)
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)

        let request = try XCTUnwrap(payload["request"] as? [String: Any])
        XCTAssertEqual(request["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request["enable_itn"] as? Bool, true)
        XCTAssertEqual(request["enable_punc"] as? Bool, true)
        XCTAssertEqual(request["enable_ddc"] as? Bool, false)
        XCTAssertEqual(request["show_utterances"] as? Bool, true)
        XCTAssertEqual(request["enable_channel_split"] as? Bool, false)
        XCTAssertEqual(request["enable_speaker_info"] as? Bool, true)
        XCTAssertEqual(request["ssd_version"] as? String, "200")
        XCTAssertNotNil(request["corpus"])
    }

    func testDisablingDiarizationDoesNotSendASpeakerModel() {
        let payload = VolcFileTranscription.makeRequestPayload(
            wav: Data([0]), enableSpeakerInfo: false, hotwordsContext: nil,
            outputChineseVariant: nil)
        let request = payload["request"] as? [String: Any]

        XCTAssertNil(request?["enable_speaker_info"])
        XCTAssertNil(request?["ssd_version"])
    }
}
