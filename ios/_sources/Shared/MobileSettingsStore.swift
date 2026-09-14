import SwiftUI
import ShallWeTalkCore

enum LLMProvider: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek 官方"
    case ark = "火山方舟 · 豆包 Flash"
    case custom = "自定义端点"
    var id: String { rawValue }
}

/// 正式 App 的网络线路。API 直连保留为升级兼容项；用户可在设置中切换两条中继线路。
/// 「海外连接」对应 Cloudflare Worker，「国内连接」对应腾讯云中继。
enum MobileNetworkRoute: String, CaseIterable, Identifiable {
    case overseas = "overseasWorker"
    case domestic = "domesticWorker"
    case direct = "apiDirect"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "API直连"
        case .overseas: return "海外连接"
        case .domestic: return "国内连接"
        }
    }

    var detail: String {
        switch self {
        case .direct: return "沿用当前正式版直连"
        case .overseas: return "Cloudflare Worker"
        case .domestic: return "腾讯云 Worker"
        }
    }

    var usesWorker: Bool { self != .direct }
}

/// 可进入源码的公开服务默认值。凭证必须保持为空，并由用户在本机设置中填写。
private enum MobileServiceDefaults {
    static let volcWsURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
    static let volcResourceID = "volc.seedasr.sauc.duration"
    static let llmProvider = LLMProvider.deepseek.rawValue
    static let llmBaseURL = "https://api.deepseek.com/v1"
    static let llmModel = "deepseek-flash"
    // 仅为不可路由的配置示例；请自行配置服务，仓库不提供共享中继。
    static let cloudflareWorkerBaseURL = "https://relay-overseas.example.invalid"
    static let tencentWorkerBaseURL = "https://relay-domestic.example.invalid"
    static let workerASRPath = "/v1/asr/bigmodel_nostream"
    static let workerCleanupPath = "/v1/cleanup"
    static let workerFilePath = "/v1/asr/file"
    static let workerWarmupPath = "/warmup"
}

/// 主 App 外观:跟随系统 / 浅色 / 深色(键盘扩展跟宿主 keyboardAppearance,不受此项影响)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    var id: String { rawValue }
    /// preferredColorScheme 用值:跟随系统 = nil(不覆盖)
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 主 App 预先保持音频会话的时长。Live Activity 单次在灵动岛最长 8 小时；
/// 「直到被中断」描述的是音频待命生命周期，不承诺系统永不终止进程。
enum StandbyDuration: String, CaseIterable, Identifiable {
    case oneHour = "1 小时"
    case eightHours = "8 小时"
    case untilInterrupted = "直到被中断"

    var id: String { rawValue }
    var interval: TimeInterval? {
        switch self {
        case .oneHour: return 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .untilInterrupted: return nil
        }
    }
}

// 2026-08-03:「免切换待命」原本有「即时待命」和「画中画省电」两种实现，
// 现只保留画中画省电一种，`StandbyMethod` 连同选择器一并删除——待命开着就是画中画待命。
// 旧的 "standbyMethod" UserDefaults 键不再读写，留在磁盘上不影响任何逻辑。

/// iOS 版设置(与 macOS 同 key,精简掉热键/输入法切换等桌面专属项)
final class MobileSettingsStore: ObservableObject {
    /// DeepSeek 官方当前稳定模型标识，对应 DeepSeek-V4.1-Flash。
    /// 生产请求统一使用这个 canonical id；旧别名只在迁移兼容层出现。
    static let officialDeepSeekModel = MobileServiceDefaults.llmModel

    static func canonicalDeepSeekModel(_ model: String, providerRaw: String) -> String {
        guard providerRaw == LLMProvider.deepseek.rawValue else { return model }
        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "", "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash",
             "deepseek-v4-flash-vision-exp", "deepseek-v4-pro":
            return officialDeepSeekModel
        default:
            return model
        }
    }

    static let nativeVolcWsURL = MobileServiceDefaults.volcWsURL

    static var defaultNetworkRoute: String { MobileNetworkRoute.direct.rawValue }

    /// 只迁移旧产品默认值；用户明确填写的其它兼容端点保持原样。
    static func migratedVolcWsURL(_ value: String) -> String {
        URL(string: value)?.lastPathComponent == "bigmodel_async" ? nativeVolcWsURL : value
    }

    func binding(for keyPath: ReferenceWritableKeyPath<MobileSettingsStore, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
    /// 从 Typeless 截图导入的个人词典。保持截图中的大小写与变体；
    /// 只通过版本化迁移合并一次，避免用户日后主动删除的词再次出现。
    private static let typelessDictionaryImportVersion = 1
    private static let typelessDictionaryWords = [
        "LSQ Investment Fund SPC", "飞牛nas", "Shall we talk",
        "SPAC", "UDM Beast", "动力火车",
        "LSQ", "CTC", "容像度",
        "gmail", "立讯精密", "火山语音",
        "AB", "豆包语音模型", "App Groups",
        "Victor WU", "Ni Ming", "debug",
        "airplay", "roon", "Claude",
        "Disruptive I", "Disruptive II", "LI Xiang",
        "H200", "Pocket 4 Pro", "Roon Server",
        "Disruptive Opportunity Fund I SP", "客服", "Mac mini",
        "Safari", "飞牛 NAS", "Fund Admin Team",
        "Liyang", "Li Xiang", "Wenyan",
        "RPO", "Anthropic", "PDF",
        "Media", "命令行命令", "Cang Biao",
        "NI Ming", "IBKR", "吴名",
        "UBO", "lily", "诚意金",
        "AI", "存储芯片", "聚芯微",
        "cima", "Obsidian", "codex",
        "Wang", "Obsidian Vault", "Vault",
        "surge", "井松智能", "佛山",
        "Karpathy", "Claude.md", "raw",
        "LP", "Claude code", "NMN",
        "Ponte", "Acquired", "metalpha",
    ]
    /// 独立版本迁移：只合并本次新增的投资/AI 场景词，不会把用户
    /// 之前主动删除的 Typeless 旧词整包重新加回。
    private static let investmentDictionaryImportVersion = 1
    private static let investmentDictionaryWords = [
        "做多", "做空", "多头", "空头", "融券", "借券", "正股", "期权",
        "call", "put", "short put", "Google", "谷歌", "Gemini", "Gemini 3.5 Pro",
        "智谱", "GLM", "Kimi", "MiniMax",
    ]

    // 豆包(火山)流式识别
    @AppStorage("volcWsURL") var volcWsURLString = MobileSettingsStore.nativeVolcWsURL
    @AppStorage("volcAppId") var volcAppId = ""
    var volcAccessToken: String {
        get { KeychainSecretStore.string(for: "volcAccessToken") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "volcAccessToken") }
    }
    @AppStorage("volcResourceId") var volcResourceId = MobileServiceDefaults.volcResourceID

    // 正式 App 网络线路。旧安装没有此键时保持 API 直连，避免升级后未经用户选择改变服务路径。
    @AppStorage("networkRoute") var networkRouteRaw = MobileSettingsStore.defaultNetworkRoute
    var networkRoute: MobileNetworkRoute {
        get { MobileNetworkRoute(rawValue: networkRouteRaw) ?? .direct }
        set { networkRouteRaw = newValue.rawValue }
    }

    // 中继地址是非敏感配置，可修改；中继 token 只保存在本机钥匙串，不进入 UserDefaults/iCloud。
    @AppStorage("cloudflareWorkerBaseURL") var cloudflareWorkerBaseURLString = MobileServiceDefaults.cloudflareWorkerBaseURL
    @AppStorage("tencentWorkerBaseURL") var tencentWorkerBaseURLString = MobileServiceDefaults.tencentWorkerBaseURL

    var cloudflareWorkerToken: String {
        get { KeychainSecretStore.string(for: "cloudflareWorkerToken") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "cloudflareWorkerToken") }
    }

    var tencentWorkerToken: String {
        get { KeychainSecretStore.string(for: "tencentWorkerToken") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "tencentWorkerToken") }
    }

    var usesWorkerRelay: Bool { networkRoute.usesWorker }

    var activeWorkerBaseURLString: String {
        get {
            switch networkRoute {
            case .domestic: return tencentWorkerBaseURLString
            case .direct, .overseas: return cloudflareWorkerBaseURLString
            }
        }
        set {
            switch networkRoute {
            case .domestic: tencentWorkerBaseURLString = newValue
            case .direct, .overseas: cloudflareWorkerBaseURLString = newValue
            }
        }
    }

    var activeWorkerToken: String {
        get {
            switch networkRoute {
            case .domestic: return tencentWorkerToken
            case .direct, .overseas: return cloudflareWorkerToken
            }
        }
        set {
            switch networkRoute {
            case .domestic: tencentWorkerToken = newValue
            case .direct, .overseas: cloudflareWorkerToken = newValue
            }
        }
    }

    private var activeWorkerBaseURL: URL {
        let fallback = networkRoute == .domestic
            ? MobileServiceDefaults.tencentWorkerBaseURL
            : MobileServiceDefaults.cloudflareWorkerBaseURL
        guard let url = URL(string: activeWorkerBaseURLString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return URL(string: fallback)!
        }
        return url
    }

    var workerRelayASRURL: URL {
        var components = URLComponents(url: activeWorkerBaseURL, resolvingAgainstBaseURL: false)
        if components?.scheme == "https" { components?.scheme = "wss" }
        if components?.scheme == "http" { components?.scheme = "ws" }
        return (components?.url ?? activeWorkerBaseURL)
            .appendingPathComponent(String(MobileServiceDefaults.workerASRPath.dropFirst()))
    }

    /// `CleanupService` 会在 base URL 后追加 `/chat/completions`，因此这里必须停在 `/v1/cleanup`。
    var workerRelayCleanupBaseURL: URL {
        activeWorkerBaseURL.appendingPathComponent(String(MobileServiceDefaults.workerCleanupPath.dropFirst()))
    }

    var workerRelayFileURL: URL {
        activeWorkerBaseURL.appendingPathComponent(String(MobileServiceDefaults.workerFilePath.dropFirst()))
    }

    var workerRelayWarmupURL: URL {
        activeWorkerBaseURL.appendingPathComponent(String(MobileServiceDefaults.workerWarmupPath.dropFirst()))
    }

    var cleanupWarmupURL: URL? { usesWorkerRelay ? workerRelayWarmupURL : nil }
    var cleanupPrewarmToken: String? { usesWorkerRelay ? activeWorkerToken : nil }

    // LLM 供应商
    @AppStorage("llmProvider") var llmProviderRaw = MobileServiceDefaults.llmProvider
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .deepseek }
        set { llmProviderRaw = newValue.rawValue }
    }
    @AppStorage("llmBaseURL") var llmBaseURLString = MobileServiceDefaults.llmBaseURL
    @AppStorage("llmModel") var llmModel = MobileServiceDefaults.llmModel
    var llmKey: String {
        get { KeychainSecretStore.string(for: "llmKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "llmKey") }
    }
    @AppStorage("arkModel") var arkModel = ""
    var arkKey: String {
        get { KeychainSecretStore.string(for: "arkKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "arkKey") }
    }

    var activeLLMBaseURL: URL {
        if usesWorkerRelay { return workerRelayCleanupBaseURL }
        switch llmProvider {
        case .deepseek: return URL(string: "https://api.deepseek.com/v1")!
        case .ark: return URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        case .custom: return URL(string: llmBaseURLString) ?? URL(string: "https://api.deepseek.com/v1")!
        }
    }
    var activeLLMModel: String {
        if usesWorkerRelay { return Self.officialDeepSeekModel }
        switch llmProvider {
        case .ark: return arkModel
        case .deepseek: return Self.officialDeepSeekModel
        case .custom: return llmModel
        }
    }
    var activeLLMKey: String {
        usesWorkerRelay ? activeWorkerToken : (llmProvider == .ark ? arkKey : llmKey)
    }

    // 整理偏好
    @AppStorage("cleanupLevel") var cleanupLevelRaw = CleanupLevel.heavy.rawValue
    @AppStorage("customPrompt") var customPrompt = ""
    @AppStorage("fullCleanupThresholdSeconds") var fullCleanupThresholdSeconds =
        DictationPolicy.defaultFullCleanupThresholdSeconds
    var cleanupLevel: CleanupLevel {
        get { CleanupLevel(rawValue: cleanupLevelRaw) ?? .heavy }
        set { cleanupLevelRaw = newValue.rawValue }
    }
    /// 简繁体输出(豆包 v3 `output_zh_variant`,2026-08-16 加入)。默认简体(false)。
    @AppStorage("outputTraditionalChinese") var outputTraditionalChinese = false
    /// 传给 `VolcEngineASR`/`VolcStreamingSession` 的值;简体时不发送该字段(nil),
    /// 繁体固定用香港繁体写法("hk")。
    var outputChineseVariant: String? { outputTraditionalChinese ? "hk" : nil }

    // 外观(主 App;RootView 以同 key @AppStorage 观察并施加 .preferredColorScheme)
    @AppStorage("appearanceMode") var appearanceModeRaw = AppearanceMode.system.rawValue
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    // MARK: - 会议记录
    /// 会后权威转写(火山"录音文件识别·极速版")的说话人分离开关。默认开:会议的核心
    /// 价值就是分得清谁说的。单麦克风语音指纹分离对重叠说话/远场收音准确率有限,
    /// 设置页需要一条"尽力而为,可能标错"的说明(见 MeetingSettingsPage)。
    @AppStorage("meetingSpeakerDiarization") var meetingSpeakerDiarization = true
    /// 极速版资源 ID。极速接口允许把本机 WAV 以内联 base64 直接上传，因而不依赖公网 URL、
    /// 对象存储或额外网关；该资源 ID 与流式识别资源不同。
    @AppStorage("volcFileResourceId") var volcFileResourceId = "volc.bigasr.auc_turbo"
    /// 生成会议摘要时是否开思考模式。摘要是压缩重组任务,值得让模型多想一步。
    @AppStorage("meetingSummaryThinking") var meetingSummaryThinking = true
    /// 会议音频保留策略,见 `MeetingAudioRetention`。永远不做按容量的 LRU 裁剪。
    @AppStorage("meetingAudioRetention") var meetingAudioRetentionRaw = MeetingAudioRetention.keepForever.rawValue
    var meetingAudioRetention: MeetingAudioRetention {
        get { MeetingAudioRetention(rawValue: meetingAudioRetentionRaw) ?? .keepForever }
        set { meetingAudioRetentionRaw = newValue.rawValue }
    }

    // VAD 与隐私
    @AppStorage("vadEnabled") var vadEnabled = true
    @AppStorage("vadSilenceSeconds") var vadSilenceSeconds = 4.0   // 默认静音 4 秒自动停(含键盘模式)
    @AppStorage("keepAudio") var keepAudio = true
    @AppStorage("iCloudSync") var iCloudSyncEnabled = false
    // 个人词典 + 纠错对跨设备同步(独立于历史文字同步的开关,默认开)
    @AppStorage("dictionarySyncEnabled") var dictionarySyncEnabled = true

    /// 空转守门员:短、干净的 ASR 终稿直接采用,不发 LLM 整理请求
    /// (判定见 `DictationPolicy.cleanupIsRedundant`)。
    ///
    /// 默认开——2026-08-16 快照实测这类占停止后整理请求的 52%,每次省 0.87 秒,
    /// 而放行判错的代价是"少删一个'嗯'"那个量级。留这个开关是为了能自己做前后对照:
    /// 关掉即恢复"每次都发请求"的旧行为,诊断日志里"空转守门员放行"那一行随之消失。
    @AppStorage("redundantCleanupGateEnabled") var redundantCleanupGateEnabled = true

    // 键盘免切换待命。是否正在待命属于本次进程/音频会话状态，不持久化；
    // 这里只保存用户下次启用时偏好的时长。
    /// 待命是**用户偏好**,不是运行时状态(2026-08-06 用户要求:装机即开,只有刻意关掉才关)。
    ///
    /// 与 `DictationController.standbyEnabled` 的分工必须分清:那个是"此刻画中画有没有真的
    /// 建起来"的运行时真相,会因为会话到期、来电中断、进程被回收而变 false;**本键不会**。
    /// 偏好为开时,每次回到前台都会按它把待命补建回来,用户不必再拨一次开关。
    @AppStorage("standbyPreferredOn") var standbyPreferredOn = true

    /// 冷启动口述结束后是否自动把用户送回宿主 App。
    ///
    /// **默认保持开启,即当前行为(固定回微信),不因加这个开关而改变任何人的默认体验。**
    /// 加它的原因是这条路今天只能回一个**硬编码**的 App:在微信里用是便利,
    /// 在备忘录/Safari 里用就是把人从原来的输入框扔进微信 —— §11.6 当年原话
    /// 「在别的 App 里唤起会把用户送到那个固定 App,比不返回更糟」,2026-09-08 真机三次复现。
    /// 在宿主身份探测做通之前,用户至少要能自己关掉它。
    @AppStorage("coldReturnEnabled") var coldReturnEnabled = true

    @AppStorage("standbyDuration") var standbyDurationRaw = StandbyDuration.oneHour.rawValue
    var standbyDuration: StandbyDuration {
        get { StandbyDuration(rawValue: standbyDurationRaw) ?? .oneHour }
        set { standbyDurationRaw = newValue.rawValue }
    }

    // 个人词典(手动 + 自动 + 屏蔽名单,与 macOS 同一套逻辑)
    @AppStorage("userDictionary") var userDictionaryRaw = ""
    @AppStorage("autoDictionary") var autoDictionaryRaw = ""
    @AppStorage("dictionaryBlocklist") var dictionaryBlocklistRaw = ""
    // 手动添加的替换词组(每行一对,source\ttarget):与自动挖掘的纠错对走同一条
    // effectiveCorrections/同步管线,区别只是来源是用户直接填的,不是从编辑历史挖出来的。
    @AppStorage("manualCorrections") var manualCorrectionsRaw = ""
    // 纠错对屏蔽名单(2026-08-19 新增,每行一个 source):与 dictionaryBlocklist 同一模式,
    // 让"删除"对手动/自动学习/云端同步三种来源的纠错对统一生效——见 deleteCorrection。
    @AppStorage("correctionsBlocklist") var correctionsBlocklistRaw = ""

    init() {
        // Upgrade the old bundled domestic endpoint only; preserve custom endpoints.
        if tencentWorkerBaseURLString == "https://relay-domestic.example.invalid" {
            tencentWorkerBaseURLString = MobileServiceDefaults.tencentWorkerBaseURL
        }
        importRelayEnrollment()
        migrateLegacyVolcEndpointIfNeeded()
        migrateLegacyDeepSeekModelIfNeeded()
        importTypelessDictionaryIfNeeded()
        importInvestmentDictionaryIfNeeded()
    }

    /// Development-device enrollment is transferred through Apple's paired-device channel,
    /// never bundled in the app. Delete the handoff only after Keychain confirms persistence.
    private func importRelayEnrollment() {
#if DEBUG
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let file = support.appendingPathComponent("relay-enrollment.json")
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(RelayEnrollment.self, from: data),
              value.credential.count >= 32 else { return }
        KeychainSecretStore.set(value.credential, for: "relayDeviceCredential")
        if KeychainSecretStore.string(for: "relayDeviceCredential") == value.credential {
            try? FileManager.default.removeItem(at: file)
            DiagLog.log("relay", "设备授权已存入钥匙串")
        }
#endif
    }

    private struct RelayEnrollment: Decodable { let credential: String }

#if DEBUG
    /// Explicit paired-device test input only. Runs the shipping Core transport on-device;
    /// records counts/timings, never speech text, authorization or provider credentials.
    @MainActor func runEnrolledRelayProbeIfRequested() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let input = support.appendingPathComponent("relay-probe.pcm")
        guard let pcm = try? Data(contentsOf: input), !pcm.isEmpty, pcm.count <= 2_000_000 else { return }
        try? FileManager.default.removeItem(at: input)
        var results: [[String: Any]] = []
        for route in [MobileNetworkRoute.overseas, .domestic] {
            let started = Date()
            var result: [String: Any] = ["route": route.rawValue, "pcmBytes": pcm.count]
            do {
                try await prepareRelaySession(force: true)
                let base = URL(string: route == .overseas ? cloudflareWorkerBaseURLString : tencentWorkerBaseURLString)!
                let token = route == .overseas ? cloudflareWorkerToken : tencentWorkerToken
                var components = URLComponents(url: base.appendingPathComponent("v1/asr/bigmodel_nostream"), resolvingAgainstBaseURL: false)!
                components.scheme = "wss"
                let session = VolcStreamingSession(wsURL: components.url!, appId: "", accessToken: "",
                    resourceId: volcResourceId, protocolKind: .nostream, bearerToken: token, onPartial: { _ in })
                defer { session.cancel() }
                CleanupService.prewarm(baseURL: base, warmupURL: base.appendingPathComponent("warmup"), authToken: token)
                let connection = Task { try await session.start() }
                for offset in stride(from: 0, to: pcm.count, by: 3200) {
                    session.feed(pcm.subdata(in: offset..<min(offset + 3200, pcm.count)))
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let stopped = Date()
                try await connection.value
                let raw = try await session.finish()
                guard !raw.isEmpty else { throw NSError(domain: "RelayProbe", code: 1) }
                result["asrCharacters"] = raw.count
                result["stopToFinalMillis"] = Int(Date().timeIntervalSince(stopped) * 1000)
                let cleanupStart = Date()
                let cleaner = CleanupService(baseURL: base.appendingPathComponent("v1/cleanup"), apiKey: token, model: "deepseek-flash")
                let clean = try await cleaner.clean(raw: raw, systemPrompt: PromptBuilder.buildSimple())
                result["cleanupCharacters"] = clean.count
                result["cleanupMillis"] = Int(Date().timeIntervalSince(cleanupStart) * 1000)
                result["ok"] = !clean.isEmpty
            } catch {
                let error = error as NSError
                result["ok"] = false
                result["errorDomain"] = error.domain
                result["errorCode"] = error.code
            }
            result["totalMillis"] = Int(Date().timeIntervalSince(started) * 1000)
            results.append(result)
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: support.appendingPathComponent("relay-probe-result.json"), options: .atomic)
            }
            DiagLog.log("relay", "真机样本测试 route=\(route.rawValue) ok=\(result["ok"] ?? false)")
        }
    }
#endif
    private struct RelaySession: Decodable { let token: String; let expiresAt: Double }
    @MainActor private var relayRefresh: Task<RelaySession, Error>?

    /// Renew on app entry and before cloud work. One device grant serves both relays,
    /// which share the operator's signing configuration; provider keys never reach iOS.
    @MainActor func prepareRelaySession(force: Bool = false) async throws {
        guard usesWorkerRelay || force else { return }
        importRelayEnrollment()
        let expiry = UserDefaults.standard.double(forKey: "relaySessionExpiresAt")
        if expiry > Date().timeIntervalSince1970 + 300,
           !cloudflareWorkerToken.isEmpty, !tencentWorkerToken.isEmpty { return }
        let credential = KeychainSecretStore.string(for: "relayDeviceCredential")
        if relayRefresh == nil {
            let route = RelayNetworkRoute(rawValue: networkRouteRaw) ?? .overseas
            relayRefresh = Task {
                if credential.isEmpty {
                    var trial = KeychainSecretStore.string(for: "relayTrialCredential")
                    if trial.isEmpty {
                        trial = RelaySessionClient.newTrialCredential()
                        KeychainSecretStore.set(trial, for: "relayTrialCredential")
                        guard KeychainSecretStore.string(for: "relayTrialCredential") == trial else {
                            throw NSError(domain: "Relay", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法保存试用身份，请解锁设备后重试。"])
                        }
                    }
                    let value = try await RelaySessionClient.trial(credential: trial, preferred: route)
                    return RelaySession(token: value.token, expiresAt: value.expiresAt)
                }
                var request = URLRequest(url: URL(string: MobileServiceDefaults.cloudflareWorkerBaseURL + "/v1/session")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw NSError(domain: "Relay", code: 401, userInfo: [NSLocalizedDescriptionKey: "连接授权未通过，请重新激活此设备。"])
                }
                let session = try JSONDecoder().decode(RelaySession.self, from: data)
                guard !session.token.isEmpty, session.expiresAt > Date().timeIntervalSince1970 + 60 else {
                    throw NSError(domain: "Relay", code: 401, userInfo: [NSLocalizedDescriptionKey: "连接授权已过期。"])
                }
                return session
            }
        }
        defer { relayRefresh = nil }
        let session = try await relayRefresh!.value
        cloudflareWorkerToken = session.token
        tencentWorkerToken = session.token
        guard cloudflareWorkerToken == session.token, tencentWorkerToken == session.token else {
            throw NSError(domain: "Relay", code: 500, userInfo: [NSLocalizedDescriptionKey: "设备无法保存连接授权，请解锁手机后重试。"])
        }
        UserDefaults.standard.set(session.expiresAt, forKey: "relaySessionExpiresAt")
        DiagLog.log("relay", "连接授权已更新")
    }

    /// 旧安装曾把 async 基础地址写入 UserDefaults，再在调用点临时替换为 nostream。
    /// 现在持久化值本身就是产品实际使用的原生端点；这里只做一次旧值迁移。
    private func migrateLegacyVolcEndpointIfNeeded() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: "volcWsURL") else { return }
        let migrated = Self.migratedVolcWsURL(stored)
        if migrated != stored { defaults.set(migrated, forKey: "volcWsURL") }
    }


    private func migrateLegacyDeepSeekModelIfNeeded() {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "llmProvider") ?? LLMProvider.deepseek.rawValue
        guard let stored = defaults.string(forKey: "llmModel") else { return }
        let migrated = Self.canonicalDeepSeekModel(stored, providerRaw: provider)
        if migrated != stored {
            defaults.set(migrated, forKey: "llmModel")
        }
    }

    private func importTypelessDictionaryIfNeeded() {
        let defaults = UserDefaults.standard
        let versionKey = "typelessDictionaryImportVersion"
        guard defaults.integer(forKey: versionKey) < Self.typelessDictionaryImportVersion else { return }

        var merged = parseLines(defaults.string(forKey: "userDictionary") ?? "")
        var seen = Set(merged)
        for word in Self.typelessDictionaryWords where seen.insert(word).inserted {
            merged.append(word)
        }
        defaults.set(merged.joined(separator: "\n"), forKey: "userDictionary")
        defaults.set(Self.typelessDictionaryImportVersion, forKey: versionKey)
    }

    private func importInvestmentDictionaryIfNeeded() {
        let defaults = UserDefaults.standard
        let versionKey = "investmentDictionaryImportVersion"
        guard defaults.integer(forKey: versionKey) < Self.investmentDictionaryImportVersion else { return }
        var merged = parseLines(defaults.string(forKey: "userDictionary") ?? "")
        var seen = Set(merged)
        for word in Self.investmentDictionaryWords where seen.insert(word).inserted { merged.append(word) }
        defaults.set(merged.joined(separator: "\n"), forKey: "userDictionary")
        defaults.set(Self.investmentDictionaryImportVersion, forKey: versionKey)
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var manualDictionaryWords: [String] { parseLines(userDictionaryRaw) }
    var autoDictionaryWords: [String] { parseLines(autoDictionaryRaw) }
    var blockedDictionaryWords: Set<String> { Set(parseLines(dictionaryBlocklistRaw)) }
    var dictionaryWords: [String] {
        var out = manualDictionaryWords
        for w in autoDictionaryWords where !out.contains(w) { out.append(w) }
        return out
    }

    @discardableResult
    func addDictionaryWord(_ value: String) -> Bool {
        let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !dictionaryWords.contains(word) else { return false }
        objectWillChange.send()
        userDictionaryRaw = (manualDictionaryWords + [word]).joined(separator: "\n")
        dictionaryBlocklistRaw = blockedDictionaryWords.filter { $0 != word }.sorted().joined(separator: "\n")
        return true
    }

    @discardableResult
    func updateDictionaryWord(_ oldWord: String, to value: String) -> Bool {
        let newWord = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newWord.isEmpty else { return false }

        var manual = manualDictionaryWords
        if let index = manual.firstIndex(of: oldWord) {
            manual[index] = newWord
        } else {
            manual.append(newWord) // 自动学习词编辑后转为用户明确维护的手动词
        }
        var seen = Set<String>()
        manual = manual.filter { seen.insert($0).inserted }

        objectWillChange.send()
        userDictionaryRaw = manual.joined(separator: "\n")
        autoDictionaryRaw = autoDictionaryWords.filter { $0 != oldWord && $0 != newWord }.joined(separator: "\n")
        if oldWord != newWord { addToDictionaryBlocklist(oldWord) }
        return true
    }

    func deleteDictionaryWord(_ word: String) {
        objectWillChange.send()
        userDictionaryRaw = manualDictionaryWords.filter { $0 != word }.joined(separator: "\n")
        autoDictionaryRaw = autoDictionaryWords.filter { $0 != word }.joined(separator: "\n")
        addToDictionaryBlocklist(word) // 防止自动学习稍后把用户明确删除的词重新加回来
    }

    private func addToDictionaryBlocklist(_ word: String) {
        guard !word.isEmpty, !blockedDictionaryWords.contains(word) else { return }
        dictionaryBlocklistRaw = (parseLines(dictionaryBlocklistRaw) + [word]).joined(separator: "\n")
    }

    func blockAutoWord(_ word: String) {
        autoDictionaryRaw = autoDictionaryWords.filter { $0 != word }.joined(separator: "\n")
        addToDictionaryBlocklist(word)
    }

    // MARK: - 手动替换词组(source\ttarget 每行一对)

    var manualCorrections: [LearnedCorrection] {
        parseLines(manualCorrectionsRaw).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return LearnedCorrection(source: parts[0], target: parts[1])
        }
    }

    /// 新增或覆盖一条替换词组;source 按大小写不敏感去重(用户要的是"无论识别成什么大小写
    /// 都替换成同一个写法",同一个词组不该因大小写不同而重复存在)。
    /// 顺带把这个 source 从屏蔽名单摘除:用户明确重新添加,等于撤销此前的删除。
    @discardableResult
    func addManualCorrection(source: String, target: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty, !s.contains("\t"), !t.contains("\t") else { return false }
        objectWillChange.send()
        let remaining = manualCorrections.filter { $0.source.caseInsensitiveCompare(s) != .orderedSame }
        manualCorrectionsRaw = (remaining + [LearnedCorrection(source: s, target: t)])
            .map { "\($0.source)\t\($0.target)" }.joined(separator: "\n")
        unblockCorrection(source: s)
        return true
    }

    // MARK: - 纠错对屏蔽名单(2026-08-19 新增,与 dictionaryBlocklist 同一模式)

    var blockedCorrectionSources: Set<String> { Set(parseLines(correctionsBlocklistRaw)) }

    private func unblockCorrection(source: String) {
        let lower = source.lowercased()
        correctionsBlocklistRaw = parseLines(correctionsBlocklistRaw)
            .filter { $0.lowercased() != lower }
            .joined(separator: "\n")
    }

    /// 删除一条纠错对,不分来源(手动 / 本机学习 / 云端同步)统一走这一个入口:
    /// 从手动列表摘除(如果在)+ 记入屏蔽名单。屏蔽名单同时挡住两件事——本机
    /// `DictionaryMiner` 再次挖出同一条(见 `correctionPairs` 的 `blocked` 参数),
    /// 以及下一轮同步把云端的旧版本带回来(`syncAndMerge` 会据此补一条墓碑传播出去)。
    func deleteCorrection(source: String) {
        objectWillChange.send()
        let lower = source.lowercased()
        manualCorrectionsRaw = manualCorrections
            .filter { $0.source.lowercased() != lower }
            .map { "\($0.source)\t\($0.target)" }.joined(separator: "\n")
        var blocked = parseLines(correctionsBlocklistRaw)
        if !blocked.contains(where: { $0.lowercased() == lower }) {
            blocked.append(source)
        }
        correctionsBlocklistRaw = blocked.joined(separator: "\n")
    }

    var hotwordsContext: String? { hotwordsContext(corrections: []) }

    /// 2025-06 后火山 context 已扩容到 5000 词；此处同时注入用户已确认的
    /// 带上下文纠错对。仍设 256 KiB 本地保护上限，避免异常词典撑大首包。
    /// `recentRecords` 用于附带最近 20 分钟内已产出的口述文字作为 `context_data`
    /// (对话历史,见 ASRContextBuilder),不传则等同于旧行为。
    func hotwordsContext(corrections: [LearnedCorrection], recentRecords: [DictationRecord] = []) -> String? {
        var selected: [[String: String]] = []
        var seen = Set<String>()
        // 手动/自动个人词典始终优先;键盘里至少选过两次的词再利用剩余配额。
        let candidates = dictionaryWords + SharedDictionaryStore.learnedWords(minimumCount: 2, limit: 30)
        for w in candidates where seen.insert(w).inserted {
            guard selected.count < 5_000 else { break }
            let candidate = selected + [["word": w]]
            guard let d = try? JSONSerialization.data(withJSONObject: ["hotwords": candidate]),
                  d.count <= 256 * 1024 else { break }
            selected = candidate
        }
        var payload: [String: Any] = [:]
        if !selected.isEmpty { payload["hotwords"] = selected }
        var correctWords: [String: String] = [:]
        for pair in corrections.prefix(DictionaryMiner.maxCorrectionPairs)
            where correctWords[pair.source] == nil {
            correctWords[pair.source] = pair.target
        }
        if !correctWords.isEmpty { payload["correct_words"] = correctWords }
        let contextData = ASRContextBuilder.contextData(records: recentRecords)
        if !contextData.isEmpty {
            payload["context_type"] = "dialog_ctx"
            payload["context_data"] = contextData
        }
        guard !payload.isEmpty,
              let d = try? JSONSerialization.data(withJSONObject: payload), d.count <= 256 * 1024,
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
}

/// 满足 ShallWeTalkCore.DictionarySyncCoordinator 所需的最小读写字段;字段名与协议一致,
/// 不必改动既有存储层。
extension MobileSettingsStore: DictionarySyncSettings {}
