import XCTest
@testable import ShallWeTalkCore

final class AudioTranscriptionRequestTests: XCTestCase {
    func testBuildsOpenAICompatibleMultipartRequest() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x7f])
        let request = AudioTranscriptionRequest.make(
            baseURL: try XCTUnwrap(URL(string: "https://zenmux.ai/api/v1")),
            apiKey: "test-key",
            model: "xiaomi/mimo-v2.5-asr",
            wav: wav,
            boundary: "test-boundary"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://zenmux.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=test-boundary"
        )

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model\"\r\n\r\nxiaomi/mimo-v2.5-asr"))
        XCTAssertTrue(bodyText.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(bodyText.contains("Content-Type: audio/wav"))
        XCTAssertFalse(bodyText.contains("name=\"prompt\""))
        XCTAssertNotNil(body.range(of: wav))
        XCTAssertTrue(bodyText.hasSuffix("--test-boundary--\r\n"))
    }

    func testBuildsZenMuxMiMoJSONBase64Request() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x7f])
        let request = try ZenMuxAudioTranscriptionRequest.make(
            baseURL: try XCTUnwrap(URL(string: "https://zenmux.ai/api/v1")),
            apiKey: "test-key",
            model: "xiaomi/mimo-v2.5-asr",
            wav: wav
        )

        XCTAssertEqual(request.url?.absoluteString, "https://zenmux.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 180)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "xiaomi/mimo-v2.5-asr")
        XCTAssertNil(json["language"])
        XCTAssertNil(json["enable_itn"])
        let audio = try XCTUnwrap(json["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertFalse((audio["data"] as? String)?.hasPrefix("data:") ?? true)
    }

    func testIncludesNonEmptyPromptAndOmitsWhitespacePrompt() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/v1"))
        let withPrompt = AudioTranscriptionRequest.make(
            baseURL: baseURL, apiKey: "k", model: "m", prompt: "保留中英文", wav: Data(), boundary: "b1"
        )
        XCTAssertTrue(String(decoding: try XCTUnwrap(withPrompt.httpBody), as: UTF8.self)
            .contains("name=\"prompt\"\r\n\r\n保留中英文"))

        let whitespace = AudioTranscriptionRequest.make(
            baseURL: baseURL, apiKey: "k", model: "m", prompt: "  \n", wav: Data(), boundary: "b2"
        )
        XCTAssertFalse(String(decoding: try XCTUnwrap(whitespace.httpBody), as: UTF8.self)
            .contains("name=\"prompt\""))
    }

    func testDecodesSuccessAndSurfacesHTTPError() throws {
        XCTAssertEqual(
            try AudioTranscriptionRequest.decode(data: Data(#"{"text":"测试文本"}"#.utf8), statusCode: 200),
            "测试文本"
        )

        XCTAssertThrowsError(
            try AudioTranscriptionRequest.decode(data: Data(#"{"error":"denied"}"#.utf8), statusCode: 403)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("denied"))
        }
    }
}
