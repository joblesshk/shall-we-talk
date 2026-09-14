import Foundation
import ShallWeTalkCore

/// 离线批量基准:重放历史音频,把每个 ASR 候选 × 每个 LLM 候选跑一遍,多次取中位数,
/// 主测「速度(延迟)」,同时保留文本供人工看质量。结果导出为 Markdown + CSV。
///
/// 复用现有服务:VolcEngineASR / OpenAICompatibleTranscription / ZenMuxTranscription(ASR)、CleanupService(整理)。
/// ASR 计时口径:对同一段 WAV 的整段请求「发起→拿到文本」总耗时(跨模型统一、可比;
/// 真实流式体验更低,但用于「排名谁更快」这个固定音频的批量请求耗时是公允代理)。
/// LLM 计时口径:发起→首字(TTFT)与发起→完成(总耗时)。

// MARK: - 候选模型

struct BenchASR: Identifiable, Equatable {
    let id = UUID()
    var name: String
    enum Kind: String { case volcano, openai, zenmux }
    var kind: Kind
    // volcano(豆包流式,批量整段调用)
    var wsURL = ""
    var resourceId = ""
    var appId = ""
    var accessToken = ""
    // openai 兼容 /audio/transcriptions
    var baseURL = ""
    var model = ""
    var apiKey = ""
    var prompt = ""
    static func == (a: BenchASR, b: BenchASR) -> Bool { a.id == b.id }
}

struct BenchLLM: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var baseURL: String
    var model: String
    var apiKey: String
    static func == (a: BenchLLM, b: BenchLLM) -> Bool { a.id == b.id }
}

// MARK: - 结果行

struct ASRRow: Identifiable {
    let id = UUID()
    var name: String
    var medianMs: Int
    var minMs: Int
    var maxMs: Int
    var okRuns: Int
    var totalRuns: Int
    var sampleText: String
}

struct LLMRow: Identifiable {
    let id = UUID()
    var name: String
    var medianTTFT: Int
    var medianTotal: Int
    var okRuns: Int
    var totalRuns: Int
    var sampleText: String
}

struct ComboRow: Identifiable {
    let id = UUID()
    var asrName: String
    var llmName: String
    var endToEndMs: Int   // ASR 中位数 + LLM 总耗时中位数
}

// MARK: - 跑批引擎

@MainActor
final class BatchBench: ObservableObject {
    @Published var asrCandidates: [BenchASR] = []
    @Published var llmCandidates: [BenchLLM] = []
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var progressText = ""
    @Published var asrRows: [ASRRow] = []
    @Published var llmRows: [LLMRow] = []
    @Published var comboRows: [ComboRow] = []
    @Published var lastReportPath: String?

    private let settings: SettingsStore
    private let history: HistoryStore

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
        seedCandidates()
    }

    /// 从当前设置自动播种候选(0 配置即可跑),再并入可选 JSON 扩展。
    func seedCandidates() {
        var asr: [BenchASR] = []
        let base = "wss://openspeech.bytedance.com/api/v3/sauc"
        if !settings.volcAppId.isEmpty, !settings.volcAccessToken.isEmpty {
            asr.append(BenchASR(name: "豆包2.0·nostream", kind: .volcano,
                                wsURL: "\(base)/bigmodel_nostream", resourceId: "volc.seedasr.sauc.duration",
                                appId: settings.volcAppId, accessToken: settings.volcAccessToken))
            asr.append(BenchASR(name: "豆包2.0·async（仅对照）", kind: .volcano,
                                wsURL: "\(base)/bigmodel_async", resourceId: "volc.seedasr.sauc.duration",
                                appId: settings.volcAppId, accessToken: settings.volcAccessToken))
        }
        // 第二组火山凭证(若配置)
        if !settings.volcBAppId.isEmpty, !settings.volcBAccessToken.isEmpty {
            asr.append(BenchASR(name: "豆包B", kind: .volcano,
                                wsURL: settings.volcBWsURLString, resourceId: settings.volcBResourceId,
                                appId: settings.volcBAppId, accessToken: settings.volcBAccessToken))
        }
        // OpenAI 兼容 ASR(主用或 B 用)
        if settings.asrProvider == .openai, !settings.asrKey.isEmpty {
            asr.append(BenchASR(name: "ASR主·\(settings.asrModel)", kind: .openai,
                                baseURL: settings.asrBaseURLString, model: settings.asrModel, apiKey: settings.asrKey))
        }
        if settings.asrBProvider == .openai, !settings.asrBKey.isEmpty {
            asr.append(BenchASR(name: "ASR·\(settings.asrBModel)", kind: .openai,
                                baseURL: settings.asrBBaseURLString, model: settings.asrBModel,
                                apiKey: settings.asrBKey, prompt: settings.asrBPrompt))
        }
        if settings.asrBProvider == .zenmux, !settings.zenmuxBKey.isEmpty {
            asr.append(BenchASR(name: "ASR·MiMo-V2.5-ASR (ZenMux)", kind: .zenmux,
                                baseURL: settings.zenmuxBBaseURLString, model: settings.zenmuxBModel,
                                apiKey: settings.zenmuxBKey))
        }

        var llm: [BenchLLM] = []
        if !settings.activeLLMKey.isEmpty {
            llm.append(BenchLLM(name: "LLM主·\(settings.activeLLMModel)",
                                baseURL: settings.activeLLMBaseURL.absoluteString,
                                model: settings.activeLLMModel, apiKey: settings.activeLLMKey))
        }
        if settings.llmBConfigured {
            llm.append(BenchLLM(name: "LLM·B·\(settings.llmBModel)",
                                baseURL: settings.llmBBaseURLString,
                                model: settings.llmBModel, apiKey: settings.llmBKey))
        }

        // 并入可选 JSON 扩展(去重按 name)
        let ext = loadExternalConfig()
        for a in ext.asr where !asr.contains(where: { $0.name == a.name }) { asr.append(a) }
        for l in ext.llm where !llm.contains(where: { $0.name == l.name }) { llm.append(l) }

        asrCandidates = asr
        llmCandidates = llm
    }

    // MARK: 运行

    /// 对选定音频跑批。每个测量重复 repeats 次取中位数(压网络抖动)。
    func run(clips: [DictationRecord], repeats: Int) {
        guard !isRunning else { return }
        guard !clips.isEmpty, !asrCandidates.isEmpty else {
            progressText = "没有可测的音频或 ASR 候选"; return
        }
        isRunning = true; progress = 0; progressText = "准备…"
        asrRows = []; llmRows = []; comboRows = []

        let asrList = asrCandidates
        let llmList = llmCandidates
        let clipData: [(DictationRecord, Data)] = clips.compactMap { rec in
            guard let url = history.audioURL(for: rec), let d = try? Data(contentsOf: url) else { return nil }
            return (rec, d)
        }
        let level = settings.cleanupLevel
        let custom = settings.customPrompt
        let dict = settings.dictionaryWords
        let hotwords = settings.hotwordsContext

        Task { [weak self] in
            await self?.execute(clipData: clipData, asrList: asrList, llmList: llmList,
                                repeats: max(1, repeats), level: level, custom: custom,
                                dict: dict, hotwords: hotwords)
        }
    }

    private func execute(clipData: [(DictationRecord, Data)],
                         asrList: [BenchASR], llmList: [BenchLLM], repeats: Int,
                         level: CleanupLevel, custom: String, dict: [String], hotwords: String?) async {
        let prompt = PromptBuilder.build(level: level, customInstruction: custom, dictionary: dict)

        // 累积:每个 ASR 的耗时样本 + 文本;每个 LLM 的 TTFT/总耗时样本 + 文本
        var asrMs: [String: [Int]] = [:]
        var asrText: [String: String] = [:]
        var asrOK: [String: Int] = [:]
        var asrN: [String: Int] = [:]
        var llmTTFT: [String: [Int]] = [:]
        var llmTot: [String: [Int]] = [:]
        var llmText: [String: String] = [:]
        var llmOK: [String: Int] = [:]
        var llmN: [String: Int] = [:]

        // 每个 ASR 候选留一份"代表转写稿"用于喂给 LLM(取首个成功的)
        var transcriptFor: [String: String] = [:]

        let totalUnits = Double(clipData.count * asrList.count * repeats)
        var done = 0.0

        for (ci, (_, wav)) in clipData.enumerated() {
            for a in asrList {
                for r in 0..<repeats {
                    await setProgress("识别 [\(ci+1)/\(clipData.count)] \(a.name) 第\(r+1)次", done / max(totalUnits, 1))
                    let (text, ms, ok) = await Self.runASR(a, wav: wav, hotwords: hotwords)
                    asrN[a.name, default: 0] += 1
                    if ok {
                        asrMs[a.name, default: []].append(ms)
                        asrOK[a.name, default: 0] += 1
                        if asrText[a.name] == nil { asrText[a.name] = text }
                        if transcriptFor[a.name] == nil, !text.isEmpty { transcriptFor[a.name] = text }
                    }
                    done += 1
                }
            }
        }

        // LLM:用每个 ASR 的代表稿分别喂给每个 LLM(覆盖"不同识别稿→整理"的真实链路)
        let llmUnits = Double(transcriptFor.count * llmList.count * repeats)
        var ldone = 0.0
        for (asrName, raw) in transcriptFor {
            for l in llmList {
                for r in 0..<repeats {
                    await setProgress("整理 [\(asrName)] \(l.name) 第\(r+1)次", ldone / max(llmUnits, 1))
                    let (text, ttft, tot, ok) = await Self.runLLM(l, raw: raw, prompt: prompt)
                    llmN[l.name, default: 0] += 1
                    if ok {
                        if let t = ttft { llmTTFT[l.name, default: []].append(t) }
                        llmTot[l.name, default: []].append(tot)
                        llmOK[l.name, default: 0] += 1
                        if llmText[l.name] == nil { llmText[l.name] = text }
                    }
                    ldone += 1
                }
            }
        }

        // 聚合排名
        var aRows: [ASRRow] = asrList.map { a in
            let s = asrMs[a.name] ?? []
            return ASRRow(name: a.name, medianMs: Self.median(s), minMs: s.min() ?? 0, maxMs: s.max() ?? 0,
                          okRuns: asrOK[a.name] ?? 0, totalRuns: asrN[a.name] ?? 0,
                          sampleText: asrText[a.name] ?? "")
        }.filter { $0.totalRuns > 0 }
        aRows.sort { ($0.okRuns > 0 ? $0.medianMs : Int.max) < ($1.okRuns > 0 ? $1.medianMs : Int.max) }

        var lRows: [LLMRow] = llmList.map { l in
            LLMRow(name: l.name, medianTTFT: Self.median(llmTTFT[l.name] ?? []),
                   medianTotal: Self.median(llmTot[l.name] ?? []),
                   okRuns: llmOK[l.name] ?? 0, totalRuns: llmN[l.name] ?? 0,
                   sampleText: llmText[l.name] ?? "")
        }.filter { $0.totalRuns > 0 }
        lRows.sort { ($0.okRuns > 0 ? $0.medianTotal : Int.max) < ($1.okRuns > 0 ? $1.medianTotal : Int.max) }

        var cRows: [ComboRow] = []
        for a in aRows where a.okRuns > 0 {
            for l in lRows where l.okRuns > 0 {
                cRows.append(ComboRow(asrName: a.name, llmName: l.name, endToEndMs: a.medianMs + l.medianTotal))
            }
        }
        cRows.sort { $0.endToEndMs < $1.endToEndMs }

        let report = Self.report(asr: aRows, llm: lRows, combo: cRows, clips: clipData.count, repeats: repeats)
        let path = Self.writeReport(report.md, csv: report.csv)

        asrRows = aRows; llmRows = lRows; comboRows = cRows
        lastReportPath = path
        progress = 1; progressText = "完成 · 报告已导出"
        isRunning = false
    }

    private func setProgress(_ text: String, _ p: Double) async {
        progressText = text; progress = p
    }

    // MARK: 单次调用(后台)

    nonisolated private static func runASR(_ a: BenchASR, wav: Data, hotwords: String?) async -> (String, Int, Bool) {
        let t0 = Date()
        do {
            let text: String
            switch a.kind {
            case .volcano:
                guard let url = URL(string: a.wsURL) else { return ("", 0, false) }
                text = try await VolcEngineASR(wsURL: url, appId: a.appId, accessToken: a.accessToken,
                                               resourceId: a.resourceId, hotwordsContext: hotwords)
                    .transcribe(wav: wav)
            case .openai:
                guard let url = URL(string: a.baseURL) else { return ("", 0, false) }
                text = try await OpenAICompatibleTranscription(
                    baseURL: url, apiKey: a.apiKey, model: a.model,
                    prompt: a.prompt.isEmpty ? nil : a.prompt).transcribe(wav: wav)
            case .zenmux:
                guard let url = URL(string: a.baseURL) else { return ("", 0, false) }
                text = try await ZenMuxTranscription(
                    baseURL: url, apiKey: a.apiKey, model: a.model).transcribe(wav: wav)
            }
            return (text, Int(Date().timeIntervalSince(t0) * 1000), true)
        } catch {
            return ("[err] " + error.localizedDescription, 0, false)
        }
    }

    nonisolated private static func runLLM(_ l: BenchLLM, raw: String, prompt: String) async -> (String, Int?, Int, Bool) {
        final class Box: @unchecked Sendable { var ttft: Int? }
        let t0 = Date(); let box = Box()
        guard let url = URL(string: l.baseURL) else { return ("", nil, 0, false) }
        do {
            let text = try await CleanupService(baseURL: url, apiKey: l.apiKey, model: l.model)
                .cleanStream(raw: raw, systemPrompt: prompt) { _ in
                    if box.ttft == nil { box.ttft = Int(Date().timeIntervalSince(t0) * 1000) }
                }
            return (text, box.ttft, Int(Date().timeIntervalSince(t0) * 1000), true)
        } catch {
            return ("[err] " + error.localizedDescription, nil, 0, false)
        }
    }

    // MARK: 统计 / 报告

    nonisolated static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count/2] : (s[s.count/2 - 1] + s[s.count/2]) / 2
    }

    nonisolated private static func report(asr: [ASRRow], llm: [LLMRow], combo: [ComboRow],
                                           clips: Int, repeats: Int) -> (md: String, csv: String) {
        let df = ISO8601DateFormatter()
        var md = "# Shall We Talk 模型速度基准\n\n"
        md += "- 时间:\(df.string(from: Date()))\n- 测试音频:\(clips) 段 · 每项重复 \(repeats) 次取中位数\n"
        md += "- 计时:ASR=整段请求发起→文本(ms);LLM=首字 TTFT / 总耗时(ms)\n\n"
        md += "## 语音识别(按中位耗时升序)\n\n| 模型 | 中位 ms | 最快 | 最慢 | 成功率 |\n|---|--:|--:|--:|--:|\n"
        for r in asr { md += "| \(r.name) | \(r.medianMs) | \(r.minMs) | \(r.maxMs) | \(r.okRuns)/\(r.totalRuns) |\n" }
        md += "\n## 文字整理(按总耗时升序)\n\n| 模型 | 首字 TTFT | 总耗时 | 成功率 |\n|---|--:|--:|--:|\n"
        for r in llm { md += "| \(r.name) | \(r.medianTTFT) | \(r.medianTotal) | \(r.okRuns)/\(r.totalRuns) |\n" }
        md += "\n## 端到端组合(ASR中位 + LLM总耗时中位,升序)\n\n| ASR | LLM | 合计 ms |\n|---|---|--:|\n"
        for c in combo.prefix(20) { md += "| \(c.asrName) | \(c.llmName) | \(c.endToEndMs) |\n" }
        md += "\n> 速度是硬指标,质量请人工核对各模型样本文本(是否忠实、不加戏、少删信息)。\n"

        var csv = "type,name,median_ms,ttft_ms,total_ms,ok,total\n"
        for r in asr { csv += "ASR,\(r.name),\(r.medianMs),,, \(r.okRuns),\(r.totalRuns)\n" }
        for r in llm { csv += "LLM,\(r.name),,\(r.medianTTFT),\(r.medianTotal),\(r.okRuns),\(r.totalRuns)\n" }
        for c in combo { csv += "COMBO,\(c.asrName) + \(c.llmName),\(c.endToEndMs),,,,\n" }
        return (md, csv)
    }

    nonisolated private static func writeReport(_ md: String, csv: String) -> String? {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        let mdURL = dir.appendingPathComponent("Shall-We-Talk-Bench-\(stamp).md")
        let csvURL = dir.appendingPathComponent("Shall-We-Talk-Bench-\(stamp).csv")
        try? md.data(using: .utf8)?.write(to: mdURL)
        try? csv.data(using: .utf8)?.write(to: csvURL)
        return mdURL.path
    }

    // MARK: 可选 JSON 扩展配置

    private struct ExternalConfig: Decodable {
        struct A: Decodable { var name: String; var kind: String; var wsURL: String?; var resourceId: String?
            var appId: String?; var accessToken: String?; var baseURL: String?; var model: String?
            var apiKey: String?; var prompt: String? }
        struct L: Decodable { var name: String; var baseURL: String; var model: String; var apiKey: String }
        var asr: [A]?; var llm: [L]?
    }

    static var externalConfigURL: URL {
        let base = AppDataDirectory.url()
        return base.appendingPathComponent("bench_config.json")
    }

    private func loadExternalConfig() -> (asr: [BenchASR], llm: [BenchLLM]) {
        guard let data = try? Data(contentsOf: Self.externalConfigURL),
              let cfg = try? JSONDecoder().decode(ExternalConfig.self, from: data) else { return ([], []) }
        let asr: [BenchASR] = (cfg.asr ?? []).map {
            BenchASR(name: $0.name, kind: BenchASR.Kind(rawValue: $0.kind) ?? .openai,
                     wsURL: $0.wsURL ?? "", resourceId: $0.resourceId ?? "",
                     appId: $0.appId ?? "", accessToken: $0.accessToken ?? "",
                     baseURL: $0.baseURL ?? "", model: $0.model ?? "", apiKey: $0.apiKey ?? "",
                     prompt: $0.prompt ?? "")
        }
        let llm: [BenchLLM] = (cfg.llm ?? []).map {
            BenchLLM(name: $0.name, baseURL: $0.baseURL, model: $0.model, apiKey: $0.apiKey)
        }
        return (asr, llm)
    }

    /// 首次没有配置文件时写一份可编辑模板,方便加更多模型/密钥。
    func writeConfigTemplateIfNeeded() {
        let url = Self.externalConfigURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let tmpl = """
        {
          "asr": [
            {"name": "示例·gpt-4o-transcribe", "kind": "openai",
             "baseURL": "https://api.openai.com/v1", "model": "gpt-4o-transcribe", "apiKey": "sk-...",
             "prompt": "中文夹杂英文术语的口述,保留原语言。"}
          ],
          "llm": [
            {"name": "示例·豆包Flash", "baseURL": "https://ark.cn-beijing.volces.com/api/v3",
             "model": "doubao-seed-1.6-flash", "apiKey": "..."}
          ]
        }
        """
        try? tmpl.data(using: .utf8)?.write(to: url)
    }
}
