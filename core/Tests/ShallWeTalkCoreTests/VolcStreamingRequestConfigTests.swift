import XCTest
@testable import ShallWeTalkCore

/// 会议录音要给流式识别加 `enable_speaker_info`,这条测试是"会议功能不能拖累既有
/// 听写路径"的回归保护线:默认(不传会议参数)配置必须与改动前逐字节一致。
final class VolcStreamingRequestConfigTests: XCTestCase {
    func testDefaultConfigMatchesPreExistingDictationShape() {
        let config = VolcStreamingSession.requestConfig(
            enableSpeakerInfo: false,
            hotwordsContext: nil, outputChineseVariant: nil)
        let request = config["request"] as? [String: Any]
        XCTAssertNotNil(request)
        XCTAssertNil(request?["enable_speaker_info"])
        XCTAssertNil(request?["enable_nonstream"])
        XCTAssertNil(request?["corpus"])
        XCTAssertNil(request?["output_zh_variant"])
        XCTAssertEqual(request?["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request?["enable_itn"] as? Bool, true)
        XCTAssertEqual(request?["enable_punc"] as? Bool, true)
        XCTAssertEqual(request?["enable_ddc"] as? Bool, true)
        XCTAssertEqual(request?["show_utterances"] as? Bool, true)
        XCTAssertEqual(request?["result_type"] as? String, "full")

        let audio = config["audio"] as? [String: Any]
        XCTAssertEqual(audio?["format"] as? String, "pcm")
        XCTAssertEqual(audio?["rate"] as? Int, 16000)
        XCTAssertEqual(audio?["channel"] as? Int, 1)
    }

    func testSpeakerInfoOnlyPresentWhenRequested() {
        let off = VolcStreamingSession.requestConfig(
            enableSpeakerInfo: false,
            hotwordsContext: nil, outputChineseVariant: nil)
        XCTAssertNil((off["request"] as? [String: Any])?["enable_speaker_info"])

        let on = VolcStreamingSession.requestConfig(
            enableSpeakerInfo: true,
            hotwordsContext: nil, outputChineseVariant: nil)
        XCTAssertEqual((on["request"] as? [String: Any])?["enable_speaker_info"] as? Bool, true)
    }

    func testNeverSendsChannelSplit() {
        let config = VolcStreamingSession.requestConfig(
            enableSpeakerInfo: true,
            hotwordsContext: "ctx", outputChineseVariant: "hk")
        XCTAssertNil((config["request"] as? [String: Any])?["enable_channel_split"])
    }

    func testMeetingModeConfigStillCarriesOptionalFields() {
        let config = VolcStreamingSession.requestConfig(
            enableSpeakerInfo: true,
            hotwordsContext: "{\"hotwords\":[]}", outputChineseVariant: "hk")
        let request = config["request"] as? [String: Any]
        XCTAssertEqual(request?["enable_speaker_info"] as? Bool, true)
        XCTAssertNil(request?["enable_nonstream"])
        XCTAssertEqual(request?["output_zh_variant"] as? String, "hk")
        XCTAssertNotNil(request?["corpus"])
    }
}
