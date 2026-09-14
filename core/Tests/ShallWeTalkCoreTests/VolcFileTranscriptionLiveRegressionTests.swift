import XCTest
@testable import ShallWeTalkCore

/// 可选的真机"录音文件识别·极速版"(会议结束后的权威转写来源)回归,需要环境变量提供
/// 火山凭据和一段真实录音(VOLC_APP_ID / VOLC_ACCESS_TOKEN / VOLC_FILE_RESOURCE_ID /
/// AUDIO_PATH)。无凭据时整个测试跳过。
///
/// 按会议记录功能实施计划:这条测试必须在把 `MeetingRecordingController` 的转写替换逻辑
/// 接进真实录音之前,先对着真实账号跑一次——`VolcFileTranscription` 里内联音频字段
/// (`audio.data`)、说话人字段路径(`additions.speaker`)都是按公开资料与第三方交叉验证
/// 推断的,不是官方示例直接给出的,这是最低成本的核实方式。
final class VolcFileTranscriptionLiveRegressionTests: XCTestCase {
    func testTranscribeAgainstLiveAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let appID = environment["VOLC_APP_ID"], !appID.isEmpty,
            let token = environment["VOLC_ACCESS_TOKEN"], !token.isEmpty,
            let resourceID = environment["VOLC_FILE_RESOURCE_ID"], !resourceID.isEmpty,
            let audioPath = environment["AUDIO_PATH"], !audioPath.isEmpty
        else {
            throw XCTSkip("set VOLC_APP_ID, VOLC_ACCESS_TOKEN, VOLC_FILE_RESOURCE_ID and AUDIO_PATH to run the live file-transcription regression")
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let result = try await VolcFileTranscription.transcribe(
            wav: wav, appId: appID, accessToken: token, resourceId: resourceID,
            enableSpeakerInfo: true)

        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "File transcription returned empty text")
        if !result.utterances.isEmpty {
            let withSpeaker = result.utterances.filter { $0.speakerID != nil }.count
            print("[live-regression] \(result.utterances.count) utterances, \(withSpeaker) carry a speakerID")
        }
    }
}
