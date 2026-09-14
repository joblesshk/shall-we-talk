import Foundation

/// OpenAI-compatible `audio/transcriptions` multipart request builder.
///
/// Keeping the wire-format builder in the shared core makes the protocol independently testable;
/// platform apps remain responsible for executing the request with their own URLSession.
public enum AudioTranscriptionRequest {
    public static func make(
        baseURL: URL,
        apiKey: String,
        model: String,
        prompt: String? = nil,
        wav: Data,
        boundary: String = "Boundary-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(name: "model", value: model, boundary: boundary, to: &body)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    public static func decode(data: Data, statusCode: Int) throws -> String {
        guard statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AudioTranscription",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ASR 请求失败: \(message.prefix(200))"]
            )
        }
        struct Response: Decodable { let text: String }
        return try JSONDecoder().decode(Response.self, from: data).text
    }

    private static func appendField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
}

/// ZenMux's `audio/transcriptions` wire format.
///
/// Unlike OpenAI's multipart endpoint, ZenMux requires a JSON body whose `input_audio.data`
/// contains raw Base64 bytes. See ZenMux's Create transcription API reference.
public enum ZenMuxAudioTranscriptionRequest {
    public static func make(
        baseURL: URL,
        apiKey: String,
        model: String,
        wav: Data,
        language: String? = nil,
        enableITN: Bool? = nil
    ) throws -> URLRequest {
        struct InputAudio: Encodable {
            let data: String
            let format: String
        }
        struct Payload: Encodable {
            let model: String
            let inputAudio: InputAudio
            let language: String?
            let enableITN: Bool?

            enum CodingKeys: String, CodingKey {
                case model
                case inputAudio = "input_audio"
                case language
                case enableITN = "enable_itn"
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(
            model: model,
            inputAudio: InputAudio(data: wav.base64EncodedString(), format: "wav"),
            language: language,
            enableITN: enableITN
        ))
        return request
    }
}
