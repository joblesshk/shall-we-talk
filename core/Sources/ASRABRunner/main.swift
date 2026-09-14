import Foundation
import Security
import ShallWeTalkCore

private struct HistoryRecord: Decodable {
    let id: UUID
    let date: Date
    let rawText: String
    let cleanText: String?
    let finalText: String?
    let audioFileName: String?
}

/// `开发数据/真实语音评测/<snapshot>/dataset/paired-cases.jsonl` 里的一条。
///
/// 用 `--dataset <快照目录>` 指向它,就能拿 iPhone 上几个月的真实口述跑分,
/// 而不是 Mac 上那 20 段以自测为主的录音。两者的差别不只是量:这份快照里
/// 56 段 ≤4 秒的真实短口述,正是上一轮唯一没能回答的那个问题所缺的样本。
private struct PairedCase: Decodable {
    struct Audio: Decodable { let bytes: Int; let durationMs: Double? }
    let recordId: String
    let recordedAt: Date
    let rawText: String?
    let audioPath: String
    let audio: Audio

    enum CodingKeys: String, CodingKey {
        case recordId = "record_id"
        case recordedAt = "recorded_at"
        case rawText = "raw_text"
        case audioPath = "audio_path"
        case audio
    }
    enum AudioKeys: String, CodingKey { case bytes; case durationMs = "duration_ms" }
}

extension PairedCase.Audio {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PairedCase.AudioKeys.self)
        bytes = try c.decode(Int.self, forKey: .bytes)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
    }
}

private struct TimedResult: Codable {
    let text: String
    let milliseconds: Int
    let error: String?

    var succeeded: Bool { error == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct ClipResult: Codable {
    let id: UUID
    let date: Date
    let audioFileName: String
    let durationSeconds: Double
    let historicalRawText: String
    let a: TimedResult
    let b: TimedResult
    /// 可选第三臂。加它是因为 ElevenLabs 的 no_verbatim 必须与它自己的逐字稿并排看:
    /// 只跟豆包比,分不清差异来自识别能力还是来自它在识别阶段就删了填充词。
    let c: TimedResult?
    let normalizedSimilarity: Double?
}

/// 一个可跑的识别臂。豆包走 WebSocket 异步接口,其余走各家的 HTTP 批量接口。
private enum Engine: String {
    case doubao
    case zenmux
    case elevenlabs        // 逐字
    case elevenlabsClean = "elevenlabs-clean"   // no_verbatim=true

    var label: String {
        switch self {
        case .doubao: return "豆包 SeedASR 2.0"
        case .zenmux: return "ZenMux"
        case .elevenlabs: return "ElevenLabs scribe_v2（逐字）"
        case .elevenlabsClean: return "ElevenLabs scribe_v2（no_verbatim）"
        }
    }
}

@main
private enum ASRABRunner {
    /// 配置错误(尤其是 key)是这个工具最常见的失败,而 Swift 的顶层抛错会打印一整段
    /// `Fatal error: Error raised at top level` 加 UserInfo 转储,把那句人话埋在噪音里。
    /// 这里接住并只打印消息本身。
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data(("\n错误：" + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let defaults = UserDefaults(suiteName: "org.example.VoicePen")!
        let appData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shall We Talk", isDirectory: true)
        let historyURL = appData.appendingPathComponent("history.json")
        let audioDirectory = appData.appendingPathComponent("audio", isDirectory: true)

        // macOS AppStorage writes to the standard defaults domain. Keep the
        // suite fallback for older experiment builds that used the shared suite.
        let appID = UserDefaults.standard.string(forKey: "volcAppId")
            ?? defaults.string(forKey: "volcAppId")
            ?? ""
        let accessToken = keychainSecret("volcAccessToken") ?? defaults.string(forKey: "volcAccessToken") ?? ""
        // --endpoint:覆盖 A 臂(豆包)的端点,不改动持久化设置。用于临时用单向流式
        // (bigmodel_nostream)或其它端点重跑历史存档,而不影响 App 里的生产默认值。
        let volcURLString = argumentValue("--endpoint")
            ?? UserDefaults.standard.string(forKey: "volcWsURL")
            ?? defaults.string(forKey: "volcWsURL")
            ?? "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
        let resourceID = argumentValue("--resource-id")
            ?? UserDefaults.standard.string(forKey: "volcResourceId")
            ?? defaults.string(forKey: "volcResourceId")
            ?? "volc.seedasr.sauc.duration"
        // --a-only:只跑豆包 A 臂,跳过 B/C(不需要 ZenMux/ElevenLabs key,专门用来
        // 单独验证 A 臂参数改动(如 enable_ddc/show_utterances)的效果)。
        let aOnly = CommandLine.arguments.contains("--a-only")
        // --realtime:按真实语速(200ms/块)喂音频,而不是一次性灌完,用来测量
        // "连接从录音开始就建好、边说边传"这种真实用法下,停止说话后单向流式真正
        // 要等多久——而不是重放历史 WAV 时一次性发送的最差情况耗时。
        let realtimePacing = CommandLine.arguments.contains("--realtime")
        // --via-session:用 VolcStreamingSession(发送/接收并发跑的长连接结构)而不是
        // VolcEngineASR.transcribe()(发完再收的一次性结构)来发音频。--realtime 配合
        // VolcEngineASR 测长音频会在纯发送阶段把连接拖死(实测 80s 音频在发送满 80s
        // 都没开始收包时被判定失联断开);VolcStreamingSession 的 sendLoop/receiveLoop
        // 并发跑,不会有这个问题,用它才能测出"连接从录音开始建立、边说边传"这种真实
        // 用法下,单向流式停止说话后真正要等多久。
        let viaSession = CommandLine.arguments.contains("--via-session")
        let zenMuxKey = defaults.string(forKey: "zenmuxBKey") ?? ""
        let zenMuxBaseString = defaults.string(forKey: "zenmuxBBaseURL") ?? "https://zenmux.ai/api/v1"
        let zenMuxModel = defaults.string(forKey: "zenmuxBModel") ?? "xiaomi/mimo-v2.5-asr"

        // --check-key:只验 key,不碰音频、不花钱。设完 key 应该先跑这个。
        if CommandLine.arguments.contains("--check-key") {
            try await checkElevenLabsKey(defaults: defaults)
            return
        }

        // --b / --c 选臂。默认保持原行为(B=ZenMux、无 C 臂),不动既有跑法。
        // ElevenLabs 三臂对比:--b elevenlabs --c elevenlabs-clean
        let engineB = Engine(rawValue: argumentValue("--b") ?? "zenmux")
        let engineC = argumentValue("--c").flatMap(Engine.init(rawValue:))
        guard let engineB else { throw runnerError("--b 只支持 zenmux、elevenlabs、elevenlabs-clean") }
        if argumentValue("--c") != nil, engineC == nil {
            throw runnerError("--c 只支持 zenmux、elevenlabs、elevenlabs-clean")
        }
        // 纯识别对比默认关掉两边的词表偏置:豆包挂着 5000 条 hotwords 而 ElevenLabs 不挂
        // 就不公平,两边都挂又测不出识别能力本身。--hotwords on 可以切回带偏置的对比。
        let hotwordsEnabled = (argumentValue("--hotwords") ?? "off") == "on"
        // --language:锁定 ElevenLabs 的识别语种(ISO-639-1/3)。留空走自动检测。
        // 2026-08-16 实测:自动检测在 ≤4 秒片段上会漂到约鲁巴语/德语/俄语(3/237),
        // 因为短音频给检测器的信号太少。锁 zho 应能消除漂移,代价是真英文短句可能被掰成中文。
        let language = argumentValue("--language")

        let usesEleven = !aOnly && [engineB, engineC].contains { $0 == .elevenlabs || $0 == .elevenlabsClean }
        let usesZenMux = !aOnly && [engineB, engineC].contains { $0 == .zenmux }
        guard !appID.isEmpty, !accessToken.isEmpty else {
            throw runnerError("当前识别 A 的豆包 App ID 或 Access Token 未配置")
        }
        if usesZenMux, zenMuxKey.isEmpty { throw runnerError("ZenMux API Key 未配置") }
        // 起跑前把 key 验穿:上一版是跑到发第一段音频才 401,20 段白跑。
        let elevenKey = usesEleven ? try await checkElevenLabsKey(defaults: defaults) : ""
        guard let volcURL = URL(string: volcURLString), let zenMuxBase = URL(string: zenMuxBaseString) else {
            throw runnerError("A/B 服务地址无效")
        }

        var clips: [(HistoryRecord, URL)]
        if let audioPath = argumentValue("--audio") {
            let url = URL(fileURLWithPath: audioPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw runnerError("指定的 WAV 不存在: \(audioPath)")
            }
            clips = [(HistoryRecord(id: UUID(), date: Date(), rawText: "", cleanText: nil,
                                    finalText: nil, audioFileName: url.lastPathComponent), url)]
        } else if let snapshot = argumentValue("--dataset") {
            clips = try pairedClips(snapshotPath: snapshot)
        } else {
            let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(contentsOf: historyURL))
            clips = records.compactMap { record -> (HistoryRecord, URL)? in
                guard let name = record.audioFileName else { return nil }
                let url = audioDirectory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (record, url)
            }.sorted { $0.0.date < $1.0.date }
        }
        // --max-seconds:按时长上限筛子集。短口述是上一轮唯一没答完的问题,
        // 用它可以只跑 ≤4 秒那一批,而不必把整份快照都发出去。
        if let cap = argumentValue("--max-seconds").flatMap(Double.init) {
            clips = clips.filter { (try? Data(contentsOf: $0.1).count).map { Double($0 - 44) / 32_000 <= cap } ?? false }
        }
        // --min-seconds:按时长下限筛子集。用来单独复跑长句(比如验证超时预算改动),
        // 不必把整批短音频也重跑一遍。
        if let floor = argumentValue("--min-seconds").flatMap(Double.init) {
            clips = clips.filter { (try? Data(contentsOf: $0.1).count).map { Double($0 - 44) / 32_000 >= floor } ?? false }
        }
        if let limit = argumentValue("--limit").flatMap(Int.init), limit > 0 {
            clips = Array(clips.prefix(limit))
        }
        guard !clips.isEmpty else { throw runnerError("没有找到可重放的历史 WAV") }

        let vocabulary = dictionaryTerms(defaults: defaults)
        // 复现正式 App 的短期对话上下文，专门验证它是否拖慢服务端终稿。默认不带，
        // 避免让常规 A/B 跑分受随时间变化的历史记录影响。
        let hotwords = CommandLine.arguments.contains("--recent-context")
            ? recentContext(from: historyURL)
            : (hotwordsEnabled ? hotwordsContext(vocabulary) : nil)
        let keyterms = hotwordsEnabled ? vocabulary : []
        var results: [ClipResult] = []
        let labelB = engineB == .zenmux ? zenMuxModel : engineB.label
        print("开始 ASR-only A/B：\(clips.count) 段；A=豆包 SeedASR，B=\(labelB)"
            + (engineC.map { "，C=\($0.label)" } ?? "") + "；不调用文字整理。")
        print("识别语种：\(language.map { "锁定 " + $0 } ?? "自动检测")")
        print("词表偏置：\(hotwordsEnabled ? "开（豆包 hotwords + ElevenLabs keyterms，注意 keyterms 有 20% 附加费）" : "关（两边都不挂，测纯识别）")")

        for (index, item) in clips.enumerated() {
            let (record, audioURL) = item
            let wav = try Data(contentsOf: audioURL)
            let duration = max(0, Double(wav.count - 44) / 32_000.0)
            print("[\(index + 1)/\(clips.count)] \(audioURL.lastPathComponent) \(String(format: "%.1f", duration))s")

            async let a = timed {
                if viaSession {
                    return try await runViaStreamingSession(
                        wsURL: volcURL, appId: appID, accessToken: accessToken,
                        resourceId: resourceID, hotwordsContext: hotwords,
                        wav: wav, realtimePacing: realtimePacing)
                }
                var svc = VolcEngineASR(
                    wsURL: volcURL,
                    appId: appID,
                    accessToken: accessToken,
                    resourceId: resourceID,
                    hotwordsContext: hotwords
                )
                svc.realtimePacing = realtimePacing
                return try await svc.transcribe(wav: wav)
            }
            async let b = aOnly ? TimedResult(text: "", milliseconds: 0, error: nil) : await timed {
                try await run(engine: engineB, wav: wav, zenMuxBase: zenMuxBase,
                              zenMuxKey: zenMuxKey, zenMuxModel: zenMuxModel,
                              elevenKey: elevenKey, keyterms: keyterms, language: language)
            }
            async let c: TimedResult? = aOnly ? nil : await timedIfPresent(engineC) { engine in
                try await run(engine: engine, wav: wav, zenMuxBase: zenMuxBase,
                              zenMuxKey: zenMuxKey, zenMuxModel: zenMuxModel,
                              elevenKey: elevenKey, keyterms: keyterms, language: language)
            }
            let (resultA, resultB, resultC) = await (a, b, c)
            print("  A \(resultA.succeeded ? "OK" : "FAIL") \(resultA.milliseconds)ms"
                + " · B \(resultB.succeeded ? "OK" : "FAIL") \(resultB.milliseconds)ms"
                + (resultC.map { " · C \($0.succeeded ? "OK" : "FAIL") \($0.milliseconds)ms" } ?? ""))
            results.append(ClipResult(
                id: record.id,
                date: record.date,
                audioFileName: audioURL.lastPathComponent,
                durationSeconds: duration,
                historicalRawText: record.rawText,
                a: resultA,
                b: resultB,
                c: resultC,
                normalizedSimilarity: similarity(resultA.text, resultB.text)
            ))
        }

        let reportsDirectory = appData.appendingPathComponent("bench", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let baseName = "ASR-AB-current-pair-\(stamp)"
        let markdownURL = reportsDirectory.appendingPathComponent(baseName + ".md")
        let jsonURL = reportsDirectory.appendingPathComponent(baseName + ".json")
        try markdown(results: results, aName: "豆包 SeedASR 2.0", bName: labelB,
                     cName: engineC?.label, hotwordsEnabled: hotwordsEnabled)
            .write(to: markdownURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(results).write(to: jsonURL, options: .atomic)
        print("REPORT_MD \(markdownURL.path)")
        print("REPORT_JSON \(jsonURL.path)")
    }

    private static func keychainSecret(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.voicepen.credentials",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解析 key → 形状体检 → 打一次免费的 /v1/user。三关都过才返回 key。
    /// 三关分别对应三种曾经发生或容易发生的失败:没设、设成了占位符、设了但服务端不认。
    @discardableResult
    private static func checkElevenLabsKey(defaults: UserDefaults) async throws -> String {
        let resolved = try ElevenLabsASR.resolveKey(defaults: defaults)
        print("ElevenLabs key 来源：\(resolved.origin)")
        print("指纹：\(ElevenLabsASR.fingerprint(resolved.value))")

        let (data, response) = try await URLSession.shared.data(
            for: ElevenLabsASR.validationRequest(apiKey: resolved.value))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let message = ElevenLabsASR.validationMessage(statusCode: status, body: data) {
            throw runnerError(message)
        }
        print("校验通过：服务端接受这把 key。")
        return resolved.value
    }

    /// 用 VolcStreamingSession(发送/接收并发的长连接结构)重放一段历史 WAV,可选按
    /// 真实语速(100ms/块,和生产 sendLoop 的攒包节奏一致)喂音频,测"连接从头建好、
    /// 边说边传"这种真实用法下,停止说话后真正要等多久——由调用方在 stderr 读
    /// `[via-session]` 那行尾部等待耗时。
    private static func runViaStreamingSession(
        wsURL: URL, appId: String, accessToken: String, resourceId: String,
        hotwordsContext: String?, wav: Data, realtimePacing: Bool
    ) async throws -> String {
        let pcm = wav.count > 44 ? wav.subdata(in: 44..<wav.count) : wav
        var finalText = ""
        var confirmedPrefix = ""
        let printUtterances = CommandLine.arguments.contains("--print-utterances")
        let session = VolcStreamingSession(
            wsURL: wsURL, appId: appId, accessToken: accessToken, resourceId: resourceId,
            hotwordsContext: hotwordsContext,
            audioPacketBytesOverride: argumentValue("--session-packet-bytes").flatMap(Int.init),
            paceAudioPackets: CommandLine.arguments.contains("--pace-session-packets"),
            onPartial: { _ in },
            onUtterance: { u in
                confirmedPrefix += u.text
                if printUtterances {
                    FileHandle.standardError.write(Data(
                        "  [utterance-definite] [\(u.startMs)-\(u.endMs)ms] \(u.text)\n".utf8))
                }
            }
        )
        // 默认以 100ms 切片。--feed-chunk-bytes 用于复现 AVAudioConverter
        // 在不同输入采样率下产生的变长回调，验证封包边界是否影响终稿。
        let chunkSize = max(2, argumentValue("--feed-chunk-bytes").flatMap(Int.init) ?? 3200)
        let prestartMillis = max(0, argumentValue("--prestart-audio-ms").flatMap(Int.init) ?? 0)
        let prestartBytes = min(pcm.count, prestartMillis * 32)
        var offset = 0
        // 复现生产时序：录音 tap 已开始产出，但 WebSocket 配置帧仍未发送完成。
        // `.unbounded` AsyncStream 会先积压这些 PCM；start() 成功创建 sendLoop 后，
        // 它们会在没有真实时间节流的情况下被集中冲发。
        while offset < prestartBytes {
            let end = min(offset + chunkSize, prestartBytes)
            session.feed(pcm.subdata(in: offset..<end))
            offset = end
        }
        try await session.start()
        // 用于验证生产端是否应在用户按下录音键之前预热 WebSocket。若连接能在无
        // 音频的空闲期保持可用，首包的配置握手就不会与录音同时竞争，能直接消除
        // Mac 端本次观测到的“开始后数秒才真正发出配置”的积压来源。
        let idleAfterStartMillis = max(0, argumentValue("--idle-after-start-ms").flatMap(Int.init) ?? 0)
        if idleAfterStartMillis > 0 {
            FileHandle.standardError.write(Data(
                "  [via-session] 建连后空闲预热=\(idleAfterStartMillis)ms\n".utf8))
            try await Task.sleep(nanoseconds: UInt64(idleAfterStartMillis) * 1_000_000)
        }
        if prestartMillis > 0 {
            FileHandle.standardError.write(Data(
                "  [via-session] 配置前预积压=\(prestartMillis)ms/\(prestartBytes)B\n".utf8))
        }
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            let fedBytes = end - offset
            session.feed(pcm.subdata(in: offset..<end))
            offset = end
            if realtimePacing, offset < pcm.count {
                // 16kHz / Int16 / mono = 32,000 bytes/s。测试变长音频回调时
                // 必须按该块的真实时长节流，否则会把封包实验变成发送速率实验。
                let nanos = UInt64(Double(fedBytes) / 32_000.0 * 1_000_000_000.0)
                try await Task.sleep(nanoseconds: nanos)
            }
        }
        let lastFeedAt = Date()
        do {
            finalText = try await session.finish()
        } catch {
            let d = session.diagnostics
            FileHandle.standardError.write(Data(
                "  [via-session] failure config=\(d.configurationSent) audio=\(d.audioBytesSent)B/\(d.audioPacketCount) packets resultFrames=\(d.resultFrameCount) final=\(d.receivedFinalResult) error=\(d.lastErrorDescription ?? error.localizedDescription)\n".utf8))
            session.cancel()
            throw error
        }
        let tailMs = Int(Date().timeIntervalSince(lastFeedAt) * 1000)
        FileHandle.standardError.write(Data(
            "  [via-session] 最后一块音频喂完 → 收到终稿 尾部等待 = \(tailMs)ms\n".utf8))
        if printUtterances {
            let match = confirmedPrefix == finalText
            let line = "  [utterance-definite] 拼接分句\(match ? "与终稿完全一致 ✅" : "和终稿不一致 ⚠️")"
                + (match ? "\n" : "\n    拼接: \(confirmedPrefix)\n    终稿: \(finalText)\n")
            FileHandle.standardError.write(Data(line.utf8))
        }
        return finalText
    }

    private static func run(engine: Engine, wav: Data, zenMuxBase: URL, zenMuxKey: String,
                            zenMuxModel: String, elevenKey: String,
                            keyterms: [String], language: String?) async throws -> String {
        let request: URLRequest
        switch engine {
        case .doubao:
            throw runnerError("豆包固定为 A 臂，不能选作 B/C")
        case .zenmux:
            request = try ZenMuxAudioTranscriptionRequest.make(
                baseURL: zenMuxBase, apiKey: zenMuxKey, model: zenMuxModel, wav: wav)
        case .elevenlabs, .elevenlabsClean:
            request = ElevenLabsASR.make(
                apiKey: elevenKey, wav: wav,
                noVerbatim: engine == .elevenlabsClean,
                keyterms: keyterms,
                languageCode: language)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch engine {
        case .elevenlabs, .elevenlabsClean:
            return try ElevenLabsASR.decode(data: data, statusCode: status)
        default:
            return try AudioTranscriptionRequest.decode(data: data, statusCode: status)
        }
    }

    /// 读 iPhone 真实语音快照的 `dataset/paired-cases.jsonl`。
    /// audio_path 是相对 dataset 目录写的,按那个基准解析。
    private static func pairedClips(snapshotPath: String) throws -> [(HistoryRecord, URL)] {
        let root = URL(fileURLWithPath: (snapshotPath as NSString).expandingTildeInPath)
        let datasetDir = root.appendingPathComponent("dataset")
        let jsonl = datasetDir.appendingPathComponent("paired-cases.jsonl")
        guard let text = try? String(contentsOf: jsonl, encoding: .utf8) else {
            throw runnerError("读不到 \(jsonl.path)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var clips: [(HistoryRecord, URL)] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let c = try? decoder.decode(PairedCase.self, from: data) else { continue }
            let url = URL(fileURLWithPath: c.audioPath, relativeTo: datasetDir).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let record = HistoryRecord(id: UUID(uuidString: c.recordId) ?? UUID(),
                                       date: c.recordedAt,
                                       rawText: c.rawText ?? "", cleanText: nil,
                                       finalText: nil, audioFileName: url.lastPathComponent)
            clips.append((record, url))
        }
        return clips.sorted { $0.0.date < $1.0.date }
    }

    private static func argumentValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func timedIfPresent(_ engine: Engine?,
                                       _ operation: (Engine) async throws -> String) async -> TimedResult? {
        guard let engine else { return nil }
        return await timed { try await operation(engine) }
    }

    private static func timed(_ operation: () async throws -> String) async -> TimedResult {
        let started = Date()
        do {
            let text = try await operation()
            return TimedResult(text: text, milliseconds: Int(Date().timeIntervalSince(started) * 1_000), error: nil)
        } catch {
            return TimedResult(text: "", milliseconds: Int(Date().timeIntervalSince(started) * 1_000), error: error.localizedDescription)
        }
    }

    private static func dictionaryTerms(defaults: UserDefaults) -> [String] {
        let manual = parseLines(defaults.string(forKey: "userDictionary") ?? "")
        let automatic = parseLines(defaults.string(forKey: "autoDictionary") ?? "")
        var seen = Set<String>()
        return (manual + automatic).filter { seen.insert($0).inserted }
    }

    private static func hotwordsContext(_ terms: [String]) -> String? {
        let words = terms.prefix(5_000)
        guard !words.isEmpty else { return nil }
        let object: [String: Any] = ["hotwords": words.map { ["word": $0] }]
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 256 * 1_024 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func recentContext(from historyURL: URL) -> String? {
        guard let records = try? JSONDecoder().decode([HistoryRecord].self,
                                                       from: Data(contentsOf: historyURL)) else { return nil }
        let now = Date()
        let cutoff = now.addingTimeInterval(-ASRContextBuilder.lookbackSeconds)
        var used = 0
        var turns: [[String: String]] = []
        for r in records.filter({ $0.date >= cutoff }).sorted(by: { $0.date > $1.date }) {
            let text = (r.finalText ?? r.cleanText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, turns.count < ASRContextBuilder.maxTurns,
                  used + text.count <= ASRContextBuilder.tokenBudgetChars else { continue }
            turns.append(["text": text])
            used += text.count
        }
        guard !turns.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [
                "context_type": "dialog_ctx", "context_data": turns]),
              data.count <= 256 * 1_024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double? {
        let a = normalizedCharacters(lhs)
        let b = normalizedCharacters(rhs)
        guard !a.isEmpty || !b.isEmpty else { return nil }
        let distance = levenshtein(a, b)
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    private static func normalizedCharacters(_ value: String) -> [Character] {
        Array(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func markdown(results: [ClipResult], aName: String, bName: String,
                                 cName: String?, hotwordsEnabled: Bool) -> String {
        let okA = results.filter(\.a.succeeded)
        let okB = results.filter(\.b.succeeded)
        let okC = results.filter { $0.c?.succeeded == true }
        let totalDuration = results.reduce(0) { $0 + $1.durationSeconds }
        let similarities = results.compactMap(\.normalizedSimilarity)
        let meanSimilarity = similarities.isEmpty ? 0 : similarities.reduce(0, +) / Double(similarities.count)
        let cCol = cName == nil ? "" : " C |"
        let cSep = cName == nil ? "" : " ---: |"
        var output = """
        # 当前语音模型 A/B 历史音频测试

        - 生成时间：\(Date().formatted(date: .numeric, time: .standard))
        - 音频：\(results.count) 段，共 \(String(format: "%.1f", totalDuration)) 秒
        - A：\(aName)
        - B：\(bName)
        \(cName.map { "- C：\($0)\n" } ?? "")- 词表偏置：\(hotwordsEnabled ? "开" : "关（两边都不挂，测纯识别）")
        - 文字整理：未运行

        ## 汇总

        | 指标 | A | B |\(cCol)
        |---|---:|---:|\(cSep)
        | 成功 | \(okA.count)/\(results.count) | \(okB.count)/\(results.count) |\(cName == nil ? "" : " \(okC.count)/\(results.count) |")
        | 中位请求耗时 | \(median(okA.map(\.a.milliseconds))) ms | \(median(okB.map(\.b.milliseconds))) ms |\(cName == nil ? "" : " \(median(okC.compactMap { $0.c?.milliseconds })) ms |")
        | 平均字符数 | \(average(okA.map(\.a.text.count))) | \(average(okB.map(\.b.text.count))) |\(cName == nil ? "" : " \(average(okC.compactMap { $0.c?.text.count })) |")

        A/B 规范化字符平均相似度：\(String(format: "%.1f%%", meanSimilarity * 100))。该指标只表示两份转写的一致程度，不代表准确率；最终质量需结合音频人工判断。

        \(cName == nil ? "" : "「平均字符数」是判断 no_verbatim 删了多少的第一眼指标:C 明显短于 B 才说明它真的在识别阶段动了手。删得对不对仍需逐条看。\n")
        ## 逐条原始转写

        """
        for (index, result) in results.enumerated() {
            output += """
            ### \(index + 1). \(result.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f", result.durationSeconds)) 秒

            - 文件：`\(result.audioFileName)`
            - A：\(result.a.succeeded ? "成功，\(result.a.milliseconds) ms" : "失败：\(result.a.error ?? "未知错误")")
            - B：\(result.b.succeeded ? "成功，\(result.b.milliseconds) ms" : "失败：\(result.b.error ?? "未知错误")")
            - A/B 相似度：\(result.normalizedSimilarity.map { String(format: "%.1f%%", $0 * 100) } ?? "无")

            **A 原始转写**

            \(result.a.text.isEmpty ? "（无结果）" : result.a.text)

            **B 原始转写**

            \(result.b.text.isEmpty ? "（无结果）" : result.b.text)

            \(result.c.map { c in
                "**C 原始转写**（\(c.succeeded ? "成功，\(c.milliseconds) ms" : "失败：\(c.error ?? "未知错误")")）\n\n"
                    + (c.text.isEmpty ? "（无结果）" : c.text) + "\n"
            } ?? "")
            **历史记录中的原始识别稿（仅供追溯，不作为独立真值）**

            \(result.historicalRawText.isEmpty ? "（无）" : result.historicalRawText)

            """
        }
        return output
    }

    private static func average(_ values: [Int]) -> Int {
        values.isEmpty ? 0 : values.reduce(0, +) / values.count
    }

    private static func runnerError(_ message: String) -> NSError {
        NSError(domain: "ASRABRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
