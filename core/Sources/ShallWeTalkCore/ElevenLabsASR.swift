import Foundation

/// ElevenLabs Scribe v2 批量转写的线格式(2026-08-16 按官方 API 参考实现)。
///
/// 与 `AudioTranscriptionRequest` 一样只造请求、只解响应,由调用方自己执行——
/// 这样协议本身可以脱网测试。
///
/// 为什么 A/B 走批量而不是 realtime:`ASRABRunner` 是重放历史 WAV,豆包臂也是
/// 「文件进、文字出」。realtime 会把 commit 策略与 VAD 阈值一并掺进结果,
/// 测的就不再是识别能力本身。realtime 的接入是部署阶段的事,与这次对比无关。
public enum ElevenLabsASR {
    public static let defaultBaseURL = URL(string: "https://api.elevenlabs.io/v1")!
    public static let model = "scribe_v2"

    // MARK: - Key 的取得与校验
    //
    // 2026-08-16:上一版只有「`defaults write` 一条路 + 空值才报错」,结果把命令里的
    // 中文占位符原样写了进去(51 字符、含空格、非 ASCII),跑到发请求才 401。
    // 三处改法针对这次的三个失败面:
    //   ① 来源多一条不经过 shell 的(文件),粘贴时不会被引号、历史展开、占位符坑到;
    //   ② 读到就清洗并做形状体检,占位符这种一眼假的值当场拒绝,不留到 401;
    //   ③ 起跑前先打一次免费的 /v1/user,不让 20 段音频跑完才发现 key 不对。

    /// key 文件的默认位置。用编辑器写这个文件,不经过 shell,也就没有引号与历史记录问题。
    public static var keyFileURL: URL {
        // homeDirectoryForCurrentUser 只在 macOS 有;iOS 端不需要读这个文件
        // (没有 shell/dotfile 可粘贴),但要能编译,统一用跨平台的 NSHomeDirectory()。
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/voicepen/elevenlabs.key")
    }

    /// 去掉复制粘贴常见的脏东西:首尾空白、换行、以及整体被包住的引号。
    public static func sanitizeKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where s.count >= 2 && s.hasPrefix(quote) && s.hasSuffix(quote) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// 形状体检。返回 nil 表示看起来像个 key;否则返回一句人话,说清哪里不对。
    /// 这里刻意不校验长度和前缀之外的东西——真假只有服务端说了算,本函数只拦一眼假的。
    public static func keyProblem(_ key: String) -> String? {
        if key.isEmpty { return "是空的" }
        if key.contains(where: { !$0.isASCII }) {
            return "含非 ASCII 字符（\(key.count) 字符）——多半是把命令里的提示文字当成 key 粘贴了"
        }
        if key.contains(where: { $0.isWhitespace }) {
            return "中间含空格或换行（\(key.count) 字符）——复制时把周围的文字一起带进来了"
        }
        if key.count < 20 { return "只有 \(key.count) 个字符，太短了" }
        if !key.hasPrefix("sk_") {
            return "不是以 sk_ 开头（\(key.count) 字符）——ElevenLabs 的 key 形如 sk_xxxx"
        }
        return nil
    }

    /// 只露出足以分辨"是哪一把"的部分,不足以复用。
    public static func fingerprint(_ key: String) -> String {
        guard key.count > 10 else { return "（\(key.count) 字符）" }
        return "\(key.prefix(6))…\(key.suffix(4))（\(key.count) 字符）"
    }

    public struct ResolvedKey: Sendable {
        public let value: String
        public let origin: String
    }

    /// 按优先级取 key:环境变量 → key 文件 → UserDefaults。
    /// 每一级都清洗后再判空,所以一个只含空格的值不会挡住后面的来源。
    public static func resolveKey(
        defaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keyFile: URL? = nil
    ) throws -> ResolvedKey {
        // keyFile 可注入,否则测试会读到开发机上真实的 key 文件,结果随机器而变。
        let keyFileURL = keyFile ?? Self.keyFileURL
        var attempts: [(String, String)] = []
        if let raw = environment["ELEVENLABS_API_KEY"] {
            attempts.append((sanitizeKey(raw), "环境变量 ELEVENLABS_API_KEY"))
        }
        if let raw = try? String(contentsOf: keyFileURL, encoding: .utf8) {
            attempts.append((sanitizeKey(raw), "文件 \(keyFileURL.path)"))
        }
        if let raw = defaults.string(forKey: "elevenLabsKey") {
            attempts.append((sanitizeKey(raw), "UserDefaults elevenLabsKey"))
        }

        guard let hit = attempts.first(where: { !$0.0.isEmpty }) else {
            throw NSError(domain: "ElevenLabsASR", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                没找到 ElevenLabs API Key。三种设法，任选一种：
                  1) 写文件（推荐，不经过 shell）：用编辑器创建 \(keyFileURL.path)，
                     整个文件只放 key 这一行，然后 chmod 600 该文件。
                  2) 本次运行有效：export ELEVENLABS_API_KEY=sk_...
                  3) defaults write org.example.VoicePen elevenLabsKey sk_...
                设好后先跑 ASRABRunner --check-key 验一次，再跑正式对比。
                """,
            ])
        }
        if let problem = keyProblem(hit.0) {
            throw NSError(domain: "ElevenLabsASR", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(hit.1) 里的 key \(problem)。修好它，或改用别的来源。",
            ])
        }
        return ResolvedKey(value: hit.0, origin: hit.1)
    }

    /// 校验请求:拿一小段合成音频真的走一次转写。
    ///
    /// 2026-08-16 改自 `GET /v1/user`。那个端点需要 `user_read` 权限,而按最小权限配的
    /// key 做转写根本不需要它,于是一把完全可用的 key 被报成「服务端拒绝」。
    /// 教训是校验要验你真正要用的那条路——现在这个请求与正式转写走同一个端点、
    /// 同一套权限,过了就是真的能跑。代价是 0.25 秒音频。
    public static func validationRequest(baseURL: URL = defaultBaseURL, apiKey: String) -> URLRequest {
        make(baseURL: baseURL, apiKey: apiKey, wav: probeWAV())
    }

    /// 0.25 秒、16 kHz 单声道的低音量正弦。用纯静音有被判成空音频的风险,
    /// 而官方要求音频至少 100ms。
    static func probeWAV(milliseconds: Int = 250, sampleRate: Int = 16_000) -> Data {
        let frames = sampleRate * milliseconds / 1_000
        var samples = Data(capacity: frames * 2)
        for i in 0..<frames {
            let value = Int16(3_000 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func append(_ ascii: String) { wav.append(contentsOf: Array(ascii.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count))
        wav.append(samples)
        return wav
    }

    /// 把校验结果翻成人话,并把「key 无效」与「key 有效但权限不够」分开——
    /// 两者都是 401,但前者要换 key,后者只要去后台给这把 key 勾上缺的权限。
    public static func validationMessage(statusCode: Int, body: Data) -> String? {
        if statusCode == 200 { return nil }
        let detail = errorDetail(body)
        if let detail, detail.status == "missing_permissions" {
            return "这把 key 是有效的，但权限不够：\(detail.message)\n"
                + "去 ElevenLabs 后台给这把 key 补上所需权限，或换一把权限更全的 key。"
        }
        switch statusCode {
        case 401, 403:
            return "服务端拒绝了这把 key（HTTP \(statusCode)）：\(detail?.message ?? snippet(body))"
        default:
            return "校验请求失败（HTTP \(statusCode)）：\(detail?.message ?? snippet(body))"
        }
    }

    struct ErrorDetail { let status: String; let message: String }

    /// ElevenLabs 的错误体形如 {"detail":{"status":"...","message":"..."}}，
    /// 但也见过 detail 直接是字符串的情况，两种都收。
    static func errorDetail(_ data: Data) -> ErrorDetail? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let detail = root["detail"] as? [String: Any] {
            return ErrorDetail(status: detail["status"] as? String ?? "",
                               message: detail["message"] as? String ?? "")
        }
        if let detail = root["detail"] as? String {
            return ErrorDetail(status: "", message: detail)
        }
        return nil
    }

    private static func snippet(_ data: Data) -> String {
        String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
    }

    /// - Parameters:
    ///   - noVerbatim: 官方 `no_verbatim`。开启后模型在识别阶段就去掉填充词、
    ///     false starts 与非语音噪音。仅 scribe_v2 支持。
    ///   - keyterms: 官方 `keyterms`,作用类似豆包的 hotwords,但代价明确写在文档里:
    ///     **额外 20% 费用**,且超过 100 条时每次请求按最少 20 秒计费。上限 1000 条、
    ///     每条 <50 字符、≤5 个词,且不得含 `<>{}[]\`。这里做了截断与过滤,
    ///     不合规的条目直接丢弃而不是让整个请求 422。
    ///   - languageCode: 留 nil 走自动检测。中英混说的口述不建议锁 `zho`——
    ///     锁定语种会压低夹杂英文术语的识别质量。
    ///   - tagAudioEvents: 官方 `tag_audio_events` **默认为 true**,会把
    ///     `[mouse clicking]`、`[background noise]` 这类环境音标签写进正文。
    ///     2026-08-16 首轮实测就撞上了:0.6 秒的噪音片段转写出 `[mouse clicking]`。
    ///     语音输入法把结果直接打进用户光标,这种标签是硬伤,所以这里默认关掉——
    ///     与官方默认相反是有意的。注意 `no_verbatim` 并不会顺带关掉它,实测
    ///     no_verbatim 那一臂照样吐出了 `[鼠标点击声]`。
    public static func make(
        baseURL: URL = defaultBaseURL,
        apiKey: String,
        wav: Data,
        noVerbatim: Bool = false,
        keyterms: [String] = [],
        languageCode: String? = nil,
        tagAudioEvents: Bool = false,
        boundary: String = "Boundary-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("speech-to-text"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(name: "model_id", value: model, boundary: boundary, to: &body)
        if noVerbatim {
            appendField(name: "no_verbatim", value: "true", boundary: boundary, to: &body)
        }
        if !tagAudioEvents {
            appendField(name: "tag_audio_events", value: "false", boundary: boundary, to: &body)
        }
        if let languageCode, !languageCode.isEmpty {
            appendField(name: "language_code", value: languageCode, boundary: boundary, to: &body)
        }
        for term in sanitizedKeyterms(keyterms) {
            appendField(name: "keyterms", value: term, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    /// 官方文档写死的约束,超限会让整个请求 422。宁可丢掉不合规的词条,
    /// 也不要因为词典里混进一条 23 字的基金全名而让整段音频转写失败。
    static func sanitizedKeyterms(_ terms: [String]) -> [String] {
        let banned = Set("<>{}[]\\")
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard !term.isEmpty, term.count < 50 else { return false }
                guard !term.contains(where: { banned.contains($0) }) else { return false }
                guard term.split(separator: " ").count <= 5 else { return false }
                return seen.insert(term).inserted
            }
            .prefix(1_000)
            .map { $0 }
    }

    public static func decode(data: Data, statusCode: Int) throws -> String {
        guard statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ElevenLabsASR",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ElevenLabs 转写失败(\(statusCode)): \(message.prefix(300))"]
            )
        }
        struct Response: Decodable { let text: String }
        return try JSONDecoder().decode(Response.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
}
