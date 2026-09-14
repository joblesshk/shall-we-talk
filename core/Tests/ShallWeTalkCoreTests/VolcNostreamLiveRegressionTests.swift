import XCTest
@testable import ShallWeTalkCore

/// 可选的真机 SeedASR 2.0 原生 nostream 回归,需要环境变量提供火山凭据和一段真实录音
/// (VOLC_WS_URL / VOLC_APP_ID / VOLC_ACCESS_TOKEN / VOLC_RESOURCE_ID / AUDIO_PATH)。
final class VolcNostreamLiveRegressionTests: XCTestCase {
    func testNostreamDecodingAgainstLiveAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let urlText = environment["VOLC_WS_URL"],
            let url = URL(string: urlText),
            let appID = environment["VOLC_APP_ID"], !appID.isEmpty,
            let token = environment["VOLC_ACCESS_TOKEN"], !token.isEmpty,
            let resourceID = environment["VOLC_RESOURCE_ID"], !resourceID.isEmpty,
            let audioPath = environment["AUDIO_PATH"], !audioPath.isEmpty
        else {
            throw XCTSkip("set VOLC_WS_URL, VOLC_APP_ID, VOLC_ACCESS_TOKEN, VOLC_RESOURCE_ID and AUDIO_PATH to run the live nostream regression")
        }

        guard url.lastPathComponent == "bigmodel_nostream" else {
            XCTFail("VOLC_WS_URL must point to the native bigmodel_nostream endpoint")
            return
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let result = try await VolcEngineASR(
            wsURL: url,
            appId: appID,
            accessToken: token,
            resourceId: resourceID
        ).transcribe(wav: wav)

        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Native nostream ASR returned empty text")
    }
}
