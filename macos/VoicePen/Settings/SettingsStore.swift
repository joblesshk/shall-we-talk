import Foundation
import SwiftUI
import AppKit
import Carbon.HIToolbox
import ShallWeTalkCore

/// 设置持久化(UserDefaults)。API key 上线前迁 Keychain,MVP 先求跑通
enum ASRProvider: String, CaseIterable, Identifiable, Sendable {
    case volcano = "豆包(火山)流式识别"
    case openai = "OpenAI 兼容端点"
    var id: String { rawValue }
}

/// A/B 实验的第二路 ASR 可使用标准整段转写或供应商专用实时协议。
enum ASRBProvider: String, CaseIterable, Identifiable, Sendable {
    case zenmux = "ZenMux · 小米 MiMo"
    case qwen = "阿里千问 Qwen-ASR"
    case openai = "OpenAI GPT/Whisper"
    case volcano = "第二组豆包流式"
    var id: String { rawValue }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek 官方"
    case ark = "火山方舟 · 豆包 Flash"
    case custom = "自定义端点"
    var id: String { rawValue }
}

/// 界面外观:跟随系统 / 浅色 / 深色。与 iOS `MobileSettingsStore.AppearanceMode` 同 rawValue、
/// 同 UserDefaults key("appearanceMode"),仅生效机制不同——macOS 无 SwiftUI 单一根视图覆盖
/// 全部窗口(菜单栏面板/悬浮 HUD/CompareLab/BatchBench 均为独立 AppKit 窗口),改用
/// `NSApp.appearance` 全局覆盖(见 AppState.applyAppearance()),自动级联到所有未自行设置
/// appearance 的窗口。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
    var id: String { rawValue }
}

final class SettingsStore: ObservableObject {
    /// DeepSeek 官方当前稳定模型标识，对应 DeepSeek-V4.1-Flash。
    /// 生产请求统一使用这个 canonical id；旧别名只在迁移兼容层出现。
    static let officialDeepSeekModel = "deepseek-flash"

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

    /// Mac 主听写固定使用与 iOS 当前生产路径相同的 SeedASR 2.0 native nostream 配置。
    /// 端点和资源不是用户偏好，避免旧设备或 iCloud 恢复把主听写悄悄切回旧模型。
    static let seedASRResourceID = "volc.seedasr.sauc.duration"
    static let seedASRPrimaryWebSocketURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"

    // Preserve existing direct-API installations until the user chooses a relay.
    @AppStorage("networkRoute") var networkRouteRaw = SettingsStore.initialNetworkRoute
    private static var initialNetworkRoute: String { RelayNetworkRoute.direct.rawValue }
    var networkRoute: RelayNetworkRoute { RelayNetworkRoute(rawValue: networkRouteRaw) ?? .direct }
    var usesWorkerRelay: Bool { networkRoute.usesWorker }
    var activeWorkerToken: String { KeychainSecretStore.string(for: "relayAccessToken") }
    var workerWarmupURL: URL? { networkRoute.warmupURL }
    @MainActor private var relayRefresh: Task<RelayAccessSession, Error>?

    @MainActor func prepareRelaySession() async throws {
        guard usesWorkerRelay else { return }
        let expiry = UserDefaults.standard.double(forKey: "relaySessionExpiresAt")
        guard expiry <= Date().timeIntervalSince1970 + 300 || activeWorkerToken.isEmpty else { return }
        if relayRefresh == nil {
            let credential = KeychainSecretStore.string(for: "relayDeviceCredential")
            let route = networkRoute
            relayRefresh = Task {
                if !credential.isEmpty { return try await RelaySessionClient.renew(credential: credential) }
                var trial = KeychainSecretStore.string(for: "relayTrialCredential")
                if trial.isEmpty {
                    trial = RelaySessionClient.newTrialCredential()
                    KeychainSecretStore.set(trial, for: "relayTrialCredential")
                    guard KeychainSecretStore.string(for: "relayTrialCredential") == trial else {
                        throw NSError(domain: "Relay", code: 500, userInfo: [NSLocalizedDescriptionKey: "无法保存试用身份，请解锁钥匙串后重试。"])
                    }
                }
                return try await RelaySessionClient.trial(credential: trial, preferred: route)
            }
        }
        defer { relayRefresh = nil }
        let session = try await relayRefresh!.value
        KeychainSecretStore.set(session.token, for: "relayAccessToken")
        guard activeWorkerToken == session.token else {
            throw NSError(domain: "Relay", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "无法保存连接授权，请解锁钥匙串后重试。"])
        }
        UserDefaults.standard.set(session.expiresAt, forKey: "relaySessionExpiresAt")
    }

    /// Explicit device enrollment, separate from provider keys and from the app bundle.
    @MainActor func enrollRelayDevice(credential: String) async throws {
        let session = try await RelaySessionClient.renew(credential: credential)
        KeychainSecretStore.set(credential, for: "relayDeviceCredential")
        guard KeychainSecretStore.string(for: "relayDeviceCredential") == credential else {
            throw NSError(domain: "Relay", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "无法保存设备授权，请解锁钥匙串后重试。"])
        }
        KeychainSecretStore.set(session.token, for: "relayAccessToken")
        guard activeWorkerToken == session.token else {
            throw NSError(domain: "Relay", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "无法保存连接授权。"])
        }
        UserDefaults.standard.set(session.expiresAt, forKey: "relaySessionExpiresAt")
    }

    /// Operator-only explicit file handoff. Never discover or import credentials silently.
    /// The value must come from an owner-only regular file, not a command-line argument.
    @MainActor func importRelayEnrollment(from file: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 2048 else {
            throw NSError(domain: "Relay", code: 403,
                          userInfo: [NSLocalizedDescriptionKey: "授权文件必须是当前用户独占的普通文件。"])
        }
        struct Enrollment: Decodable { let credential: String }
        let enrollment = try JSONDecoder().decode(Enrollment.self, from: Data(contentsOf: file))
        try await enrollRelayDevice(credential: enrollment.credential)
        try FileManager.default.removeItem(at: file)
    }

    func binding(for keyPath: ReferenceWritableKeyPath<SettingsStore, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    // 界面外观:跟随系统 / 浅色 / 深色(默认跟随系统,与此前无覆盖时的行为一致)
    @AppStorage("appearanceMode") var appearanceModeRaw = AppearanceMode.system.rawValue
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    // ASR 供应商切换
    @AppStorage("asrProvider") var asrProviderRaw = ASRProvider.volcano.rawValue
    var asrProvider: ASRProvider {
        get { ASRProvider(rawValue: asrProviderRaw) ?? .volcano }
        set { asrProviderRaw = newValue.rawValue }
    }

    // 豆包(火山)流式语音识别:App ID + Access Token 两个凭证。主端点/资源是
    // 固定产品配置，不能被用户默认值或跨设备同步改写。
    @AppStorage("volcAppId") var volcAppId = ""
    var volcAccessToken: String {
        get { KeychainSecretStore.string(for: "volcAccessToken") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "volcAccessToken") }
    }
    var volcResourceId: String { Self.seedASRResourceID }

    /// 与 iOS 主听写保持同一个 bigmodel_nostream 端点；不会读取旧 UserDefaults 或 iCloud 值。
    var primaryASRWsURL: URL? {
        if usesWorkerRelay { return networkRoute.asrURL }
        return URL(string: Self.seedASRPrimaryWebSocketURL)
    }

    // OpenAI 兼容 ASR(备选:SiliconFlow SenseVoice 等)
    @AppStorage("asrBaseURL") var asrBaseURLString = "https://api.siliconflow.cn/v1"
    @AppStorage("asrModel") var asrModel = "FunAudioLLM/SenseVoiceSmall"
    var asrKey: String {
        get { KeychainSecretStore.string(for: "asrKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "asrKey") }
    }

    // LLM 供应商(可选项):DeepSeek 官方 / 火山方舟豆包 Flash 小模型 / 自定义端点
    @AppStorage("llmProvider") var llmProviderRaw = LLMProvider.deepseek.rawValue
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .deepseek }
        set { llmProviderRaw = newValue.rawValue }
    }

    // DeepSeek / 自定义端点共用字段(DeepSeek 官方固定使用 V4.1-Flash)
    @AppStorage("llmBaseURL") var llmBaseURLString = "https://api.deepseek.com/v1"
    @AppStorage("llmModel") var llmModel = SettingsStore.officialDeepSeekModel
    var llmKey: String {
        get { KeychainSecretStore.string(for: "llmKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "llmKey") }
    }

    // 火山方舟(Ark):与豆包 ASR 同云同区,RTT 最低;小模型 decode 快
    @AppStorage("arkModel") var arkModel = "doubao-seed-1.6-flash"
    var arkKey: String {
        get { KeychainSecretStore.string(for: "arkKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "arkKey") }
    }

    /// 整理环节实际使用的端点/模型/密钥(按供应商选项解析)
    var activeLLMBaseURL: URL {
        if let url = networkRoute.cleanupURL { return url }
        switch llmProvider {
        case .deepseek: return URL(string: "https://api.deepseek.com/v1")!
        case .ark: return URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        case .custom: return llmBaseURL
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

    init() {
        // 迁移:DeepSeek 旧别名统一升级为官方 canonical model id。
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "llmProvider") ?? LLMProvider.deepseek.rawValue
        if let stored = defaults.string(forKey: "llmModel") {
            let migrated = Self.canonicalDeepSeekModel(stored, providerRaw: provider)
            if migrated != stored { defaults.set(migrated, forKey: "llmModel") }
        }
        // 删除历史主听写端点/资源偏好；它们已改为上述不可覆盖的产品配置。
        // 这也防止旧版 iCloud 文档恢复后留下误导性的本机值。
        let d = defaults
        d.removeObject(forKey: "volcWsURL")
        d.removeObject(forKey: "volcResourceId")
        // 迁移:只有从未配置过整理 B 时,才将旧的空白 B 升级为千问预设。
        // 已有模型或密钥的用户配置一律不覆盖。
        let oldBModel = d.string(forKey: "llmBModel") ?? ""
        let oldBKey = d.string(forKey: "llmBKey") ?? ""
        if oldBModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           oldBKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.set("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", forKey: "llmBBaseURL")
            d.set("qwen3.7-plus", forKey: "llmBModel")
        } else if oldBModel == "qwen-plus",
                  (d.string(forKey: "llmBBaseURL") ?? "").contains("dashscope") {
            // 2026 新一轮 A/B 默认改用官方推荐的低延迟 Flash 档。
            d.set("qwen3.6-flash", forKey: "llmBModel")
        }
        // 2026-07:按用户要求把 ZenMux MiMo-V2.5-ASR 设为本机 A/B 识别 B。
        // 仅迁移一次,且只替换旧的默认千问预设;已经主动选择 OpenAI/豆包的配置不覆盖。
        if d.integer(forKey: "zenmuxMiMoASRBPresetVersion") < 1 {
            let current = d.string(forKey: "asrBProvider")
            if current == nil || current == ASRBProvider.qwen.rawValue {
                d.set(ASRBProvider.zenmux.rawValue, forKey: "asrBProvider")
            }
            d.set(1, forKey: "zenmuxMiMoASRBPresetVersion")
        }
        // 多模型对比已退出产品界面。保留旧 B 配置以便将来恢复，不删除用户的凭证；
        // 但必须清掉遗留开关，避免升级后仍在录音路径中意外启动第二路识别/整理。
        d.set(false, forKey: "compareMode")
        importInvestmentDictionaryIfNeeded(defaults: d)
    }

    // 整理偏好(L2)与自定义指令(L3)
    @AppStorage("cleanupLevel") var cleanupLevelRaw = CleanupLevel.heavy.rawValue
    /// 简繁体输出(豆包 v3 `output_zh_variant`,2026-08-16 加入)。默认简体(false);
    /// 开启后 ASR 直接输出香港繁体用字,不需要额外的整理或后处理步骤。
    @AppStorage("outputTraditionalChinese") var outputTraditionalChinese = false
    @AppStorage("redundantCleanupGateEnabled") var redundantCleanupGateEnabled = false
    @AppStorage("customPrompt") var customPrompt = ""
    @AppStorage("fullCleanupThresholdSeconds") var fullCleanupThresholdSeconds =
        DictationPolicy.defaultFullCleanupThresholdSeconds

    // 隐私:音频留存开关(发音分析的数据基础,默认开,可关)
    @AppStorage("keepAudio") var keepAudio = true

    // iCloud 历史同步(仅文本,音频不上云)
    @AppStorage("iCloudSync") var iCloudSyncEnabled = true
    // 个人词典 + 纠错对跨设备同步(独立于历史文字同步的开关,默认开)
    @AppStorage("dictionarySyncEnabled") var dictionarySyncEnabled = true

    // A/B 对比模式:双 ASR 同时识别 + 双 LLM 并行整理,各自计时,人工评优
    @AppStorage("compareMode") var compareModeEnabled = false
    // ASR B:可选整段 `/audio/transcriptions` 质量基准或供应商专用实时协议。
    @AppStorage("asrBProvider") var asrBProviderRaw = ASRBProvider.zenmux.rawValue
    var asrBProvider: ASRBProvider {
        get { ASRBProvider(rawValue: asrBProviderRaw) ?? .zenmux }
        set { asrBProviderRaw = newValue.rawValue }
    }
    // 火山 B(仅 A/B 实验的第二组火山凭证，不是产品主识别路径；可显式选择 async 作对照)
    @AppStorage("volcBWsURL") var volcBWsURLString = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    @AppStorage("volcBAppId") var volcBAppId = ""
    var volcBAccessToken: String {
        get { KeychainSecretStore.string(for: "volcBAccessToken") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "volcBAccessToken") }
    }
    @AppStorage("volcBResourceId") var volcBResourceId = "volc.seedasr.sauc.duration"
    // OpenAI 兼容 ASR B:默认用于中英混杂质量基准
    @AppStorage("asrBBaseURL") var asrBBaseURLString = "https://api.openai.com/v1"
    @AppStorage("asrBModel") var asrBModel = "gpt-realtime-whisper"
    var asrBKey: String {
        get { KeychainSecretStore.string(for: "asrBKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "asrBKey") }
    }
    @AppStorage("asrBPrompt") var asrBPrompt = "这是一段中文夹杂英文产品名、技术词、人名和缩写的口述。请保留说话人原本语言,不要把英文翻译成中文,不要把中文翻译成英文。"
    // ZenMux MiMo-V2.5-ASR:JSON `input_audio.data` Base64,不是 OpenAI multipart。
    // 独立保存 Key,避免切回其他 B 供应商时互相覆盖凭证。
    @AppStorage("zenmuxBBaseURL") var zenmuxBBaseURLString = "https://zenmux.ai/api/v1"
    @AppStorage("zenmuxBModel") var zenmuxBModel = "xiaomi/mimo-v2.5-asr"
    var zenmuxBKey: String {
        get { KeychainSecretStore.string(for: "zenmuxBKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "zenmuxBKey") }
    }
    // 千问 Qwen-ASR-Realtime:录音器已输出官方要求的 16kHz mono PCM。
    // 当前账户使用新加坡地域;有 Workspace 专属域名时可替换为 ap-southeast-1.maas.aliyuncs.com。
    @AppStorage("qwenBWsURL") var qwenBWsURLString = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
    @AppStorage("qwenBModel") var qwenBModel = "qwen3-asr-flash-realtime-2026-02-10"
    var qwenBKey: String {
        get { KeychainSecretStore.string(for: "qwenBKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "qwenBKey") }
    }
    @AppStorage("qwenBCorpus") var qwenBCorpus = "这是一段中文夹杂英文产品名、技术词、人名和缩写的口述。保留中英文原样。"
    // LLM B:默认匹配当前账户的新加坡地域,仍保留任意 OpenAI 兼容端点的可编辑能力。
    @AppStorage("llmBBaseURL") var llmBBaseURLString = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
    @AppStorage("llmBModel") var llmBModel = "qwen3.7-plus"
    var llmBKey: String {
        get { KeychainSecretStore.string(for: "llmBKey") }
        set { objectWillChange.send(); KeychainSecretStore.set(newValue, for: "llmBKey") }
    }

    var asrBConfigured: Bool {
        switch asrBProvider {
        case .zenmux: return !zenmuxBKey.isEmpty && !zenmuxBModel.isEmpty
        case .volcano: return !volcBAppId.isEmpty && !volcBAccessToken.isEmpty
        case .openai: return !asrBKey.isEmpty && !asrBModel.isEmpty
        case .qwen: return !activeQwenBKey.isEmpty && !qwenBModel.isEmpty
        }
    }
    var llmBConfigured: Bool { !llmBModel.isEmpty && !llmBKey.isEmpty }
    var asrBBaseURL: URL { URL(string: asrBBaseURLString) ?? URL(string: "https://api.openai.com/v1")! }
    var zenmuxBBaseURL: URL { URL(string: zenmuxBBaseURLString) ?? URL(string: "https://zenmux.ai/api/v1")! }
    var llmBBaseURL: URL { URL(string: llmBBaseURLString) ?? URL(string: "https://api.deepseek.com/v1")! }
    var qwenBWsURL: URL { URL(string: qwenBWsURLString) ?? URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime")! }
    /// 语音 B 留空时复用同一百炼账户的整理 B Key,避免重复粘贴。
    var activeQwenBKey: String { qwenBKey.isEmpty ? llmBKey : qwenBKey }

    /// 整段转写 B 的实际参数。ZenMux 与通用 OpenAI 配置相互隔离。
    var activeBatchASRBBaseURL: URL { asrBProvider == .zenmux ? zenmuxBBaseURL : asrBBaseURL }
    var activeBatchASRBKey: String { asrBProvider == .zenmux ? zenmuxBKey : asrBKey }
    var activeBatchASRBModel: String { asrBProvider == .zenmux ? zenmuxBModel : asrBModel }
    var activeBatchASRBPrompt: String? { asrBProvider == .zenmux ? nil : asrBPrompt }

    /// 套用新加坡国际站预设;语音与文字必须和 API Key 属于同一地域。
    func useQwenIntlForB() {
        qwenBWsURLString = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
        llmBBaseURLString = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        llmBModel = "qwen3.7-plus"
    }

    /// 保留中国大陆北京地域预设,供以后切换不同地域的 Key。
    func useQwenChinaForB() {
        qwenBWsURLString = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        llmBBaseURLString = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        llmBModel = "qwen3.6-flash"
    }

    // VAD 自动停止:检测到说过话后,持续静音 N 秒自动结束录音
    @AppStorage("vadEnabled") var vadEnabled = true
    @AppStorage("vadSilenceSeconds") var vadSilenceSeconds = 2.5

    // 个人词典(每行一个词):喂给 ASR 热词 + 注入整理 prompt
    @AppStorage("userDictionary") var userDictionaryRaw = ""
    // 自动学习的词(DictionaryMiner 维护)与屏蔽名单(用户移除过的词不再自动加回)
    @AppStorage("autoDictionary") var autoDictionaryRaw = ""
    @AppStorage("dictionaryBlocklist") var dictionaryBlocklistRaw = ""
    // 手动添加的替换词组(每行一对,source\ttarget):与 DictionaryMiner 自动挖掘的纠错对
    // 走同一条 effectiveCorrections/同步管线,区别只是来源是用户直接填的,不是从编辑历史挖出来的。
    @AppStorage("manualCorrections") var manualCorrectionsRaw = ""
    /// 已删除纠错对的 source 屏蔽名单。它与词典的 tombstone 规则相同：不仅隐藏云端旧
    /// 快照，更要阻止本机根据历史再次挖出同一条错误写法后把它重新同步回去。
    @AppStorage("correctionsBlocklist") var correctionsBlocklistRaw = ""

    // Power Mode:按前台 App 绑定整理档位。JSON 存在单个 key 里——条目是个位数量级,
    // 不值得为它引一层存储;读写都走下面两个访问器,不要直接碰 raw。
    @AppStorage("appProfiles") var appProfilesRaw = ""

    var appProfiles: [AppProfile] {
        get {
            guard let data = appProfilesRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AppProfile].self, from: data) else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            // @AppStorage 装在 ObservableObject 上不会自动发布变更(它是为 View 的
            // 动态属性图设计的)。设置页读的是 appProfiles 这个计算属性而不是 Binding,
            // 不显式通知的话增删改完界面不会刷新。
            objectWillChange.send()
            appProfilesRaw = json
        }
    }

    /// 该 App 有没有配过档位。没配(或没传 bundleID)时返回 nil,调用方回落全局设置。
    func appProfile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return appProfiles.first { $0.bundleID == bundleID }
    }

    func upsertAppProfile(_ profile: AppProfile) {
        var profiles = appProfiles
        if let index = profiles.firstIndex(where: { $0.bundleID == profile.bundleID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        appProfiles = profiles
    }

    func removeAppProfile(bundleID: String) {
        appProfiles = appProfiles.filter { $0.bundleID != bundleID }
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var manualDictionaryWords: [String] { parseLines(userDictionaryRaw) }
    var autoDictionaryWords: [String] { parseLines(autoDictionaryRaw) }
    var blockedDictionaryWords: Set<String> { Set(parseLines(dictionaryBlocklistRaw)) }

    /// 生效词典 = 手动 + 自动(手动优先,占热词额度在前)
    var dictionaryWords: [String] {
        var out = manualDictionaryWords
        for w in autoDictionaryWords where !out.contains(w) { out.append(w) }
        return out
    }

    /// 词典卡片界面的增删改入口,与 iOS `MobileSettingsStore` 同名方法逐一对齐——写入路径
    /// 统一改手动/自动两个 raw 字符串 + 屏蔽名单,保证 DictionarySyncCoordinator 后续同步时
    /// 墓碑(tombstone)正确生成,不绕过既有写入路径。
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

    private static let investmentDictionaryImportVersion = 1
    private static let investmentDictionaryWords = [
        "做多", "做空", "多头", "空头", "融券", "借券", "正股", "期权",
        "call", "put", "short put", "Google", "谷歌", "Gemini", "Gemini 3.5 Pro",
        "智谱", "GLM", "Kimi", "MiniMax",
    ]

    private func importInvestmentDictionaryIfNeeded(defaults: UserDefaults) {
        let versionKey = "investmentDictionaryImportVersion"
        guard defaults.integer(forKey: versionKey) < Self.investmentDictionaryImportVersion else { return }
        var merged = parseLines(defaults.string(forKey: "userDictionary") ?? "")
        var seen = Set(merged)
        for word in Self.investmentDictionaryWords where seen.insert(word).inserted { merged.append(word) }
        defaults.set(merged.joined(separator: "\n"), forKey: "userDictionary")
        defaults.set(Self.investmentDictionaryImportVersion, forKey: versionKey)
    }

    /// 内置"常用中英混热词包":国内职场/科技/日常最常混说、且 ASR 最易听错的英文词。
    /// 载入后进个人词典 → 双通道生效(优先占 ASR 热词预算 + 整理时统一写法)。
    static let mixedTermPack: [String] = [
        // 职场 / 管理
        "KPI", "OKR", "PPT", "deadline", "review", "meeting", "offer", "HR", "leader",
        "team", "project", "brief", "sync", "align", "follow up", "push", "cue", "cover",
        "deliver", "timeline", "milestone", "roadmap", "agenda", "all hands", "one on one",
        "brainstorm", "feedback", "target", "budget", "ROI", "GMV", "DAU", "MAU",
        "retention", "conversion",
        // 科技 / 开发
        "API", "token", "SDK", "bug", "debug", "deploy", "commit", "merge", "PR", "repo",
        "server", "endpoint", "request", "response", "log", "cache", "query", "release",
        "feature", "demo", "MVP", "UI", "UX", "prompt", "model", "latency",
        // 日常 / 通用
        "OK", "update", "confirm", "schedule", "email", "calendar", "presentation", "cancel",
    ]

    /// 把中英混热词包并入个人词典(去重,已存在的不重复加)。
    func loadMixedTermPack() {
        let existing = Set(manualDictionaryWords)
        let additions = Self.mixedTermPack.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        let merged = manualDictionaryWords + additions
        userDictionaryRaw = merged.joined(separator: "\n")
    }

    /// 移除一个自动学习的词,并加入屏蔽名单
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

    var blockedCorrectionSources: Set<String> { Set(parseLines(correctionsBlocklistRaw)) }

    private func unblockCorrection(source: String) {
        let lower = source.lowercased()
        correctionsBlocklistRaw = parseLines(correctionsBlocklistRaw)
            .filter { $0.lowercased() != lower }
            .joined(separator: "\n")
    }

    /// 新增或覆盖一条替换词组;source 按大小写不敏感去重(用户要的是"无论识别成什么大小写
    /// 都替换成同一个写法",同一个词组不该因大小写不同而重复存在)。
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

    func deleteManualCorrection(source: String) {
        objectWillChange.send()
        manualCorrectionsRaw = manualCorrections
            .filter { $0.source.caseInsensitiveCompare(source) != .orderedSame }
            .map { "\($0.source)\t\($0.target)" }.joined(separator: "\n")
    }

    /// 统一删除手动、本机学习和云端学习的纠错对。只有同时写入屏蔽名单，删除才是跨端
    /// 稳定语义；否则 DictionaryMiner 会在下次历史扫描时立即把它再加回来。
    func deleteCorrection(source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deleteManualCorrection(source: trimmed)
        var blocked = parseLines(correctionsBlocklistRaw)
        if !blocked.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            blocked.append(trimmed)
            correctionsBlocklistRaw = blocked.joined(separator: "\n")
        }
    }

    var hotwordsContext: String? { hotwordsContext(corrections: []) }

    /// 火山流式 ASR context：最多 5000 个热词，并注入带上下文的精确纠错对。
    /// `recentRecords` 用于附带最近 20 分钟内已产出的口述文字作为 `context_data`
    /// (对话历史,见 ASRContextBuilder),不传则等同于旧行为。
    func hotwordsContext(corrections: [LearnedCorrection], recentRecords: [DictationRecord] = []) -> String? {
        var selected: [[String: String]] = []
        var seen = Set<String>()
        // 维持 iOS 的词典原始顺序与去重语义。Mac 没有键盘词频库，故这里只使用
        // 两端都会同步的用户词典；不要再按英文优先重排，避免生成不同的服务端配置。
        for w in dictionaryWords where seen.insert(w).inserted {
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

    // 全局快捷键(默认 ⌥Space);HotkeyManager 每次按键动态读取,改完即生效
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode = kVK_Space
    @AppStorage("hotkeyModifiers") var hotkeyModifiersRaw = Int(NSEvent.ModifierFlags.option.rawValue)

    var hotkeyModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiersRaw))
    }
    var hotkeyDescription: String {
        HotkeyManager.description(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    var asrBaseURL: URL { URL(string: asrBaseURLString) ?? URL(string: "https://api.siliconflow.cn/v1")! }
    var llmBaseURL: URL { URL(string: llmBaseURLString) ?? URL(string: "https://api.deepseek.com/v1")! }
    var cleanupLevel: CleanupLevel {
        get { CleanupLevel(rawValue: cleanupLevelRaw) ?? .heavy }
        set { cleanupLevelRaw = newValue.rawValue }
    }
    /// 传给 `VolcEngineASR`/`VolcStreamingSession` 的 `output_zh_variant` 值;
    /// 简体时不发送该字段(nil),繁体固定用香港繁体写法("hk")。
    var outputChineseVariant: String? { outputTraditionalChinese ? "hk" : nil }
}

/// 满足 ShallWeTalkCore.DictionarySyncCoordinator 所需的最小读写字段;字段名与协议一致,
/// 不必改动既有存储层。
extension SettingsStore: DictionarySyncSettings {}
