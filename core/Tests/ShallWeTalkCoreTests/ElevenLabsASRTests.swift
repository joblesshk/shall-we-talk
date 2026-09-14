import XCTest
@testable import ShallWeTalkCore

/// ElevenLabs Scribe v2 批量转写的线格式契约(2026-08-16)。
/// 全部脱网:测的是请求长什么样、响应怎么解,不测识别质量。
final class ElevenLabsASRTests: XCTestCase {
    private let wav = Data("RIFF....WAVEfmt ".utf8)
    /// 一个保证不存在的路径。不注入的话测试会读到开发机上真实的 key 文件，
    /// 结果就取决于这台机器有没有配 key。
    private let absentFile = URL(fileURLWithPath: "/nonexistent/voicepen/elevenlabs.key")

    private func bodyString(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    func testHitsTheDocumentedEndpointWithApiKeyHeader() {
        let r = ElevenLabsASR.make(apiKey: "k", wav: wav)
        XCTAssertEqual(r.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(r.httpMethod, "POST")
        // ElevenLabs 用 xi-api-key，不是 Bearer——写错会 401 而不是明显的报错。
        XCTAssertEqual(r.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
    }

    func testSendsScribeV2AndTheAudioPart() {
        let body = bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav))
        XCTAssertTrue(body.contains("name=\"model_id\""))
        XCTAssertTrue(body.contains("scribe_v2"), "no_verbatim 只在 scribe_v2 上支持")
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
    }

    func testNoVerbatimIsOptInAndOmittedByDefault() {
        XCTAssertFalse(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav)).contains("no_verbatim"))
        let clean = bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav, noVerbatim: true))
        XCTAssertTrue(clean.contains("name=\"no_verbatim\""))
        XCTAssertTrue(clean.contains("true"))
    }

    /// 2026-08-16 首轮实测:0.6 秒噪音片段被转写成 `[mouse clicking]`,而输入法会把
    /// 结果直接打进用户光标。官方 tag_audio_events 默认 true,这里必须反着来。
    func testAudioEventTaggingIsOffByDefaultUnlikeTheApiDefault() {
        XCTAssertTrue(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav))
            .contains("name=\"tag_audio_events\""))
        XCTAssertTrue(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav)).contains("false"))
        XCTAssertFalse(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav, tagAudioEvents: true))
            .contains("tag_audio_events"), "显式要标签时才用官方默认")
    }

    /// no_verbatim 文档写着会去掉 non-speech sounds,但实测那一臂照样吐出 [鼠标点击声]。
    /// 两个开关互不覆盖,必须都设。
    func testNoVerbatimDoesNotImplyAudioEventsAreOff() {
        let body = bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav, noVerbatim: true))
        XCTAssertTrue(body.contains("name=\"no_verbatim\""))
        XCTAssertTrue(body.contains("name=\"tag_audio_events\""))
    }

    /// 中英混说的口述不锁语种:锁 zho 会压低夹杂英文术语的识别。
    func testLanguageCodeIsOmittedUnlessAsked() {
        XCTAssertFalse(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav)).contains("language_code"))
        XCTAssertTrue(bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav, languageCode: "zho"))
            .contains("name=\"language_code\""))
    }

    func testKeytermsAreSentAsRepeatedFields() {
        let body = bodyString(ElevenLabsASR.make(apiKey: "k", wav: wav, keyterms: ["Keychain", "灵动岛"]))
        XCTAssertEqual(body.components(separatedBy: "name=\"keyterms\"").count - 1, 2)
        XCTAssertTrue(body.contains("Keychain"))
        XCTAssertTrue(body.contains("灵动岛"))
    }

    /// 官方把这些写成硬约束,违反会让整个请求 422。个人词典里确实有 23 字的基金全名
    /// (LSQ Investment Fund SPC),不能因为一条词让整段音频转写失败。
    func testSanitizerDropsTermsThatWouldTriggerA422() {
        let dirty = [
            "OK",
            String(repeating: "长", count: 60),          // ≥50 字符
            "a b c d e f",                                // >5 个词
            "bad<term>",                                  // 含禁用字符
            "  ",                                         // 空
            "OK",                                         // 重复
        ]
        XCTAssertEqual(ElevenLabsASR.sanitizedKeyterms(dirty), ["OK"])
    }

    func testSanitizerCapsAtTheDocumentedThousand() {
        let many = (0..<1_500).map { "term\($0)" }
        XCTAssertEqual(ElevenLabsASR.sanitizedKeyterms(many).count, 1_000)
    }

    // MARK: - Key 的清洗与体检
    //
    // 2026-08-16 真实事故:给出的设置命令里带中文占位符,用户原样执行,
    // 「在这里填你的 ElevenLabs key」被当成 key 写进 UserDefaults(51 字符、含空格、非 ASCII),
    // 一直到发第一段音频才 401。下面每条测试都对应那次事故的一个环节。

    func testRejectsTheExactPlaceholderThatCausedTheOutage() {
        let placeholder = "在这里填你的 ElevenLabs key"
        XCTAssertEqual(placeholder.count, 21)
        let problem = ElevenLabsASR.keyProblem(ElevenLabsASR.sanitizeKey(placeholder))
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem!.contains("非 ASCII"), "错误信息要指向真正的原因，而不是笼统的无效")
    }

    func testRejectsTheOtherEasyPasteMistakes() {
        for (raw, hint) in [
            ("", "空"),
            ("sk_short", "太短"),
            ("pk_1234567890123456789012345", "sk_"),
            ("sk_1234567890 1234567890123", "空格"),
        ] {
            let problem = ElevenLabsASR.keyProblem(ElevenLabsASR.sanitizeKey(raw))
            XCTAssertNotNil(problem, "应当拒绝：\(raw)")
            XCTAssertTrue(problem!.contains(hint), "「\(raw)」的错误信息应提到\(hint)，实际：\(problem!)")
        }
    }

    /// 从网页复制 key 常带尾随换行,从命令行复制常带一层引号。这两种都该自动吃掉,
    /// 而不是让用户对着一个"看起来完全正确"的值排查半天。
    func testSanitizerAbsorbsTrailingNewlinesAndWrappingQuotes() {
        let good = ("sk_" + "0123456789abcdef0123456789")
        for raw in ["\(good)\n", "  \(good)  ", "\"\(good)\"", "'\(good)'\n"] {
            XCTAssertEqual(ElevenLabsASR.sanitizeKey(raw), good)
            XCTAssertNil(ElevenLabsASR.keyProblem(ElevenLabsASR.sanitizeKey(raw)))
        }
    }

    func testFingerprintIdentifiesWithoutDisclosing() {
        let key = ("sk_" + "0123456789abcdef0123456789")
        let print_ = ElevenLabsASR.fingerprint(key)
        XCTAssertTrue(print_.hasPrefix("sk_012"))
        XCTAssertTrue(print_.contains("6789"))
        XCTAssertFalse(print_.contains("abcdef"), "中段绝不能露出来")
    }

    func testResolveKeyPrefersEnvironmentAndSkipsBlankSources() throws {
        let defaults = UserDefaults(suiteName: "ElevenLabsASRTests")!
        defaults.removePersistentDomain(forName: "ElevenLabsASRTests")
        defaults.set("   ", forKey: "elevenLabsKey")   // 只含空白的来源不该挡住后面的
        let env = ["ELEVENLABS_API_KEY": ("sk_" + "0123456789abcdef0123456789\n")]
        let resolved = try ElevenLabsASR.resolveKey(defaults: defaults, environment: env, keyFile: absentFile)
        XCTAssertEqual(resolved.value, ("sk_" + "0123456789abcdef0123456789"))
        XCTAssertTrue(resolved.origin.contains("环境变量"))
        defaults.removePersistentDomain(forName: "ElevenLabsASRTests")
    }

    func testResolveKeyErrorListsEveryWayToSetIt() {
        let defaults = UserDefaults(suiteName: "ElevenLabsASRTests-empty")!
        defaults.removePersistentDomain(forName: "ElevenLabsASRTests-empty")
        XCTAssertThrowsError(try ElevenLabsASR.resolveKey(defaults: defaults, environment: [:], keyFile: absentFile)) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("elevenlabs.key"))
            XCTAssertTrue(message.contains("ELEVENLABS_API_KEY"))
            XCTAssertTrue(message.contains("--check-key"), "报错要顺手告诉用户下一步怎么验")
        }
    }

    /// 2026-08-16 真实事故之二:校验原本打 `GET /v1/user`,而那个端点要 `user_read` 权限。
    /// 用户按最小权限配的 key 做转写完全够用,却被报成「服务端拒绝这把 key」。
    /// 校验必须走将来真正要走的那条路。
    func testValidationExercisesTheSameEndpointAsRealTranscription() {
        let r = ElevenLabsASR.validationRequest(apiKey: "sk_x")
        XCTAssertEqual(r.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "xi-api-key"), "sk_x")
        XCTAssertFalse(r.url?.absoluteString.contains("/user") == true,
                       "不要再用需要 user_read 的端点做校验")
    }

    func testProbeAudioIsAValidWavAboveTheHundredMillisecondMinimum() {
        let wav = ElevenLabsASR.probeWAV()
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
        // 16 kHz、16 bit、单声道 → 每秒 32000 字节；官方要求音频不短于 100ms。
        let seconds = Double(wav.count - 44) / 32_000
        XCTAssertEqual(seconds, 0.25, accuracy: 0.001)
    }

    func testMissingPermissionsIsNotReportedAsABadKey() {
        let body = Data(#"""
        {"detail":{"type":"authentication_error","code":"unauthorized",\#
        "message":"The API key you used is missing the permission user_read to execute this operation.",\#
        "status":"missing_permissions"}}
        """#.utf8)
        let message = ElevenLabsASR.validationMessage(statusCode: 401, body: body)!
        XCTAssertTrue(message.contains("有效的，但权限不够"),
                      "权限不足与 key 无效是两回事：前者要补权限，后者要换 key")
        XCTAssertTrue(message.contains("user_read"), "要把服务端说的缺哪个权限原样带出来")
        XCTAssertFalse(message.contains("拒绝了这把 key"))
    }

    func testValidationSeparatesKeyRejectionFromOtherFailures() {
        XCTAssertNil(ElevenLabsASR.validationMessage(statusCode: 200, body: Data()))
        let rejected = ElevenLabsASR.validationMessage(
            statusCode: 401, body: Data(#"{"detail":"invalid api key"}"#.utf8))!
        XCTAssertTrue(rejected.contains("拒绝了这把 key"))
        XCTAssertTrue(rejected.contains("invalid api key"))
        let other = ElevenLabsASR.validationMessage(statusCode: 503, body: Data("busy".utf8))!
        XCTAssertTrue(other.contains("校验请求失败"))
        XCTAssertFalse(other.contains("拒绝了这把 key"), "服务端抽风不该被报成 key 有问题")
    }

    func testDecodesTheDocumentedResponseShape() throws {
        let json = #"{"language_code":"zho","language_probability":0.98,"text":" 我有个问题 ","words":[]}"#
        let text = try ElevenLabsASR.decode(data: Data(json.utf8), statusCode: 200)
        XCTAssertEqual(text, "我有个问题")
    }

    func testSurfacesTheServerMessageOnFailure() {
        XCTAssertThrowsError(
            try ElevenLabsASR.decode(data: Data(#"{"detail":"invalid api key"}"#.utf8), statusCode: 401)
        ) { error in
            XCTAssertTrue("\(error)".contains("invalid api key"),
                          "排错时必须能看见服务端原文，否则 401/422 分不清是 key 还是参数")
        }
    }
}
