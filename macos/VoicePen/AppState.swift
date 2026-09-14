import Foundation
import AVFoundation
import AppKit
import Combine
import Speech
import UserNotifications
import ShallWeTalkCore

enum AppStatus: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

/// 延迟打点用的线程安全小盒子:CleanupService.onFirstToken 在非 MainActor 上下文触发,
/// 需要一个可从任意上下文写入、finish() 结束前在 MainActor 上读回的容器。
/// 与 A/B 对比模式下 cleanTimed 里的 TTFTBox 是同一惯用法。
private final class MillisBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// 流末 token 账单的跨并发域承接盒,与 `MillisBox` 同一模式。
private final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CleanupService.Usage?
    var value: CleanupService.Usage? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private func elapsedMillis(_ date: Date?, since stopAt: Date) -> Int? {
    date.map { Int($0.timeIntervalSince(stopAt) * 1000) }
}

private func cleanupPassMetrics(startedAt: Date?, firstTokenMillis: Int?, completedAt: Date?,
                                usage: CleanupService.Usage?, requestCount: Int = 1,
                                stopAt: Date) -> CleanupPassMetrics? {
    guard startedAt != nil || firstTokenMillis != nil || completedAt != nil || usage != nil else { return nil }
    return CleanupPassMetrics(startedMillis: elapsedMillis(startedAt, since: stopAt),
                              firstTokenMillis: firstTokenMillis,
                              completedMillis: elapsedMillis(completedAt, since: stopAt),
                              requestCount: requestCount,
                              promptTokens: usage?.promptTokens,
                              cachedPromptTokens: usage?.cachedPromptTokens)
}

/// 把前缀缓存命中情况写进诊断日志。命中率直接决定首字延迟,而首字延迟是短口述
/// 等待时间的大头;没有这行,prompt 段序的调整就无法复盘。
@MainActor
private func logPromptCacheStats(_ metrics: LatencyMetrics) {
    guard let prompt = metrics.promptTokens else { return }
    let cached = metrics.cachedPromptTokens ?? 0
    let rate = metrics.promptCacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "未知"
    CoreDiagLog.log("cleanup", "prompt token=\(prompt) 命中缓存=\(cached)(\(rate))")
}

@MainActor
private func logCleanupPassStats(_ metrics: LatencyMetrics) {
    for (name, pass) in [("首轮整理", metrics.firstCleanupPass), ("结构化通读", metrics.structurePass)] {
        guard let pass else { continue }
        let rate = pass.promptCacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "未知"
        CoreDiagLog.log("cleanup", "\(name) start=\(pass.startedMillis.map { "\($0)ms" } ?? "-") "
            + "first=\(pass.firstTokenMillis.map { "\($0)ms" } ?? "-") "
            + "end=\(pass.completedMillis.map { "\($0)ms" } ?? "-") "
            + "requests=\(pass.requestCount.map(String.init) ?? "-") "
            + "prompt=\(pass.promptTokens.map(String.init) ?? "-") "
            + "cached=\(pass.cachedPromptTokens.map(String.init) ?? "-")(\(rate))")
    }
}

/// 全局状态机与口述 pipeline 编排:热键 → 录音 → ASR → LLM 整理 → 插入光标
@MainActor
final class AppState: ObservableObject {
    private var cleanupDisplayRequestID: UUID?
    private var voiceEditDisplayRequestID: UUID?
    private var insertionDisplayRequestID: UUID?
    private var recordingDisplayRequestID: UUID?
    private var recordingTargetApp: NSRunningApplication?
    @Published var status: AppStatus = .idle
    @Published var lastRawText: String = ""     // ASR 原文
    @Published var lastCleanText: String = ""   // LLM 整理稿
    @Published var autoInsert: Bool = true      // 自动插入到光标处
    @Published var insertionNote: String = ""   // 浮窗上的结果去向提示
    @Published var liveText: String = ""        // 流式识别的实时中间结果(浮窗展示)
    @Published var manualCopyMode = false       // 没找到文本输入框:浮窗显示醒目复制按钮
    @Published var audioLevel: Float = 0        // 实时音量包络(0...1),驱动波形
    @Published var streamingFellBack = false    // 本次流式失败退回整段(浮窗提示,防静默降速)
    @Published var lastDictionarySyncStatus = "未同步"
    @Published var lastHistorySyncStatus = "未同步"
    @Published private(set) var voiceEditStatus: String?
    @Published private(set) var recloudingRecordID: UUID?
    @Published private(set) var isHistorySyncing = false
    private var lastHistorySyncAt: Date?

    private var levelEnvelope: Float = 0

    // VAD 自动停止
    private var recordingStartedAt = Date()
    private var lastVoiceAt = Date()
    private var hasDetectedSpeech = false

    /// 本次口述实际生效的整理参数(全局设置 + 当前前台 App 的 Power Mode 覆盖)。
    /// 起录时解析一次并锁定:用户完全可能在等整理的几秒里切走窗口,而这次口述属于
    /// 他开口时面对的那个 App。没有为该 App 配过档位时逐字等于全局设置。
    private var activeCleanup = ResolvedCleanupSettings(
        level: .heavy, customInstruction: "", skipCleanup: false)

    /// Silero VAD。模型不可用时 `isAvailable` 为 false,语音判定自动退回 RMS 阈值。
    private let voiceActivity = VoiceActivityDriver()

    let settings = SettingsStore()
    let history = HistoryStore()
    let todos = TodoStore()

    private let recorder = Recorder()
    private var streamSession: VolcStreamingSession?
    private var streamSessionB: VolcStreamingSession? // 对比模式:第二路识别(火山流式)
    private var openaiStreamB: OpenAIRealtimeSession?  // 对比模式:B 路 OpenAI Realtime 流式(gpt-realtime-whisper)
    private var qwenStreamB: QwenRealtimeASRSession?  // 对比模式:B 路千问 Qwen-ASR-Realtime(16k PCM)
    private var streamStartErrorA: String?
    private var streamStartErrorB: String?
    @Published var compareRun: CompareRun?
    private var compareLab: CompareLabWindowController?

    // 离线批量基准(模型速度对比)
    lazy var batchBench = BatchBench(settings: settings, history: history)
    private var batchBenchWindow: BatchBenchWindowController?
    func openBatchBench() {
        batchBench.seedCandidates()
        if batchBenchWindow == nil { batchBenchWindow = BatchBenchWindowController(appState: self) }
        batchBenchWindow?.show()
    }
    private var hotkey: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var overlay: OverlayController?
    private var hideTask: Task<Void, Never>?
    /// 词典/纠错同步的防抖任务(触发点:启动/回前台、词典编辑保存后、挖掘出新纠错对后)。
    private var dictionarySyncDebounceTask: Task<Void, Never>?
    private var credentialSyncTask: Task<Void, Never>?
    private var voiceEditTarget: (id: UUID, original: String)?
    private var lastVoiceEdit: (id: UUID, originalFinal: String?)?
    private var currentRecognitionSource: RecognitionSource = .cloud

    /// 将核心会话的无敏感快照转成可持久化的本机工作记录。错误字符串做长度限制，
    /// 避免把不可读的系统底层上下文写进历史；凭据不会进入该快照。
    private func streamingWorkRecord(
        session: VolcStreamingSession?, outcome: ASRStreamingWorkRecord.Outcome,
        fallbackReason: String? = nil
    ) -> ASRStreamingWorkRecord {
        let snapshot = session?.diagnostics
        let reason = (fallbackReason ?? snapshot?.lastErrorDescription)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRStreamingWorkRecord(
            requestID: snapshot?.requestID,
            connectID: snapshot?.connectID,
            outcome: outcome,
            configurationSent: snapshot?.configurationSent ?? false,
            audioBytesSent: snapshot?.audioBytesSent ?? 0,
            audioPacketCount: snapshot?.audioPacketCount ?? 0,
            resultFrameCount: snapshot?.resultFrameCount ?? 0,
            receivedFinalResult: snapshot?.receivedFinalResult ?? false,
            firstPartialMillis: snapshot?.firstPartialMillis,
            fallbackReason: reason.map { String($0.prefix(240)) },
            parseableResultJSONFrameCount: snapshot?.parseableResultJSONFrameCount,
            resultObjectFrameCount: snapshot?.resultObjectFrameCount,
            topLevelTextPresentFrameCount: snapshot?.topLevelTextPresentFrameCount,
            topLevelNonEmptyTextFrameCount: snapshot?.topLevelNonEmptyTextFrameCount,
            utterancesPresentFrameCount: snapshot?.utterancesPresentFrameCount,
            utteranceTextPresentFrameCount: snapshot?.utteranceTextPresentFrameCount,
            definiteUtteranceTextFrameCount: snapshot?.definiteUtteranceTextFrameCount,
            finalFrameCount: snapshot?.finalFrameCount,
            finalFrameHadNonEmptyTopLevelText: snapshot?.finalFrameHadNonEmptyTopLevelText,
            onPartialInvocationCount: snapshot?.onPartialInvocationCount,
            firstParseableResultMillis: snapshot?.firstParseableResultMillis,
            firstResultObjectMillis: snapshot?.firstResultObjectMillis,
            firstTopLevelTextMillis: snapshot?.firstTopLevelTextMillis,
            firstTopLevelNonEmptyTextMillis: snapshot?.firstTopLevelNonEmptyTextMillis,
            firstUtterancesMillis: snapshot?.firstUtterancesMillis,
            firstUtteranceTextMillis: snapshot?.firstUtteranceTextMillis,
            firstDefiniteUtteranceTextMillis: snapshot?.firstDefiniteUtteranceTextMillis,
            firstFinalFrameMillis: snapshot?.firstFinalFrameMillis,
            jsonDecodeFailureCount: snapshot?.jsonDecodeFailureCount,
            decompressionFailureCount: snapshot?.decompressionFailureCount,
            sequenceFirst: snapshot?.sequenceFirst, sequenceLast: snapshot?.sequenceLast,
            sequenceMin: snapshot?.sequenceMin, sequenceMax: snapshot?.sequenceMax,
            sequenceMonotonicityBroken: snapshot?.sequenceMonotonicityBroken,
            sequenceDuplicateCount: snapshot?.sequenceDuplicateCount,
            messageTypeBucketCounts: snapshot?.messageTypeBucketCounts,
            resultFlagsBucketCounts: snapshot?.resultFlagsBucketCounts,
            timeline: snapshot.map {
                ASRStreamingTimeline(
                    configurationSentMillis: $0.configurationSentMillis,
                    firstAudioSentMillis: $0.firstAudioSentMillis,
                    lastAudioSentMillis: $0.lastAudioSentMillis,
                    finishRequestedMillis: $0.finishRequestedMillis,
                    endFrameSentMillis: $0.endFrameSentMillis,
                    endFrameSequence: $0.endFrameSequence,
                    firstResultFrameMillis: $0.firstResultFrameMillis,
                    firstTextMillis: $0.firstPartialMillis,
                    finalResultMillis: $0.finalResultMillis)
            })
    }

    init() {
        VoicePenAppDelegate.appState = self
        requestPermissions()
        Task {
            let arguments = ProcessInfo.processInfo.arguments
            do {
                if let index = arguments.firstIndex(of: "--relay-enrollment-file"), arguments.indices.contains(index + 1) {
                    try await settings.importRelayEnrollment(from: URL(fileURLWithPath: arguments[index + 1]))
                    CoreDiagLog.log("relay", "Mac 设备授权已验证并存入钥匙串，交接文件已删除")
                }
                try await settings.prepareRelaySession()
            } catch {
                CoreDiagLog.log("relay", "Mac 授权未完成：\(error.localizedDescription)")
            }
        }
        if #available(macOS 26.0, *) {
            Task.detached(priority: .utility) { await OnDeviceTranscriber.prepareAssets() }
        }
        applyAppearance()
        hotkey = HotkeyManager(settings: settings) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        // 嵌套 ObservableObject 的变更向上转发,否则历史/待办列表不刷新
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        todos.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.syncCredentials(reason: "设置变更")
            }
            .store(in: &cancellables)
        overlay = OverlayController(appState: self)
        // 启动后延迟拉取 iCloud 历史(等 bird 完成可能的下载)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { self?.syncHistoryFromCloud() }
        }
        scheduleDictionarySync(reason: "启动")
        syncCredentials(reason: "启动")
        // 菜单栏 App 的"回前台"近似:用户重新激活 App(点菜单栏图标、切到设置/历史窗口等)。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDictionarySync(reason: "回前台")
                self?.syncHistoryFromCloud(throttled: true)
                self?.syncCredentials(reason: "回前台")
            }
        }
    }

    var terminationWarning: String? {
        if status == .recording { return "录音仍在进行，请先结束录音并等待保存。" }
        if status == .processing { return "识别或整理仍在进行，请等待结果保存。" }
        if history.hasUnsavedChanges || history.persistenceError != nil || todos.persistenceError != nil {
            return "本机历史或待办尚未确认保存成功，请先处理保存错误。"
        }
        return nil
    }

    /// 与 iOS 一致的凭证恢复/推送。先读取较新的云端值，再将本机确有变化的快照推回；
    /// 文件 I/O 始终在 detached task，避免 iCloud 下载阻塞菜单栏主线程。
    func syncCredentials(reason: String) {
        credentialSyncTask?.cancel()
        credentialSyncTask = Task { [weak self] in
            // AppStorage publishes individual field changes, including when a
            // remote document is applied. Coalesce them before starting file I/O;
            // cancellation of a parent cannot stop an already detached read.
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            let remote = await Task.detached(priority: .utility) {
                CredentialSyncCoordinator.remote()
            }.value
            guard !Task.isCancelled, let self else { return }
            // 先恢复远端，再读取将要推送的本机快照；否则旧本地快照会以新时间戳
            // 覆盖更晚的远端凭证，违背 iOS 的 last-write-wins 约定。
            if let remote, CredentialSyncCoordinator.applyIfNewer(remote, to: self.settings) {
                CoreDiagLog.log("credSync", "已从 iCloud 恢复凭证 reason=\(reason)")
            }
            guard let snapshot = CredentialSyncCoordinator.localSnapshot(of: self.settings) else { return }
            let pushed = await Task.detached(priority: .utility) {
                CredentialSyncCoordinator.pushIfChanged(snapshot)
            }.value
            guard !Task.isCancelled else { return }
            if let pushed {
                CredentialSyncCoordinator.markPushed(pushed)
                CoreDiagLog.log("credSync", "已推送凭证到 iCloud reason=\(reason)")
            }
        }
    }

    /// 双向历史同步:拉取云端合并 + 补传云端缺失的本机记录。
    /// 由启动、回前台(节流)、历史窗口打开、云朵按钮、设置页触发。
    /// iCloud 文件 I/O 可能同步等待下载/网络,绝不能占用 MainActor(历史 0x8BADF00D 教训)。
    /// - Parameter throttled: true 时 60 秒内已同步过就跳过(回前台这类高频触发用)。
    func syncHistoryFromCloud(throttled: Bool = false) {
        guard settings.iCloudSyncEnabled else {
            lastHistorySyncStatus = "同步未开启"
            return
        }
        guard !isHistorySyncing else { return }
        if throttled, let last = lastHistorySyncAt, Date().timeIntervalSince(last) < 60 { return }
        isHistorySyncing = true
        lastHistorySyncStatus = "正在同步…"
        CoreDiagLog.log("historySync", "开始同步 本地 \(history.records.count) 条")
        let localRecords = history.records
        let localDeletions = history.deletionTombstones
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> CloudHistorySync.PullResult? in
                guard let pull = CloudHistorySync.pull(
                    into: localRecords, localDeletions: localDeletions) else { return nil }
                return pull
            }.value
            guard let self else { return }
            guard let result else {
                self.isHistorySyncing = false
                self.lastHistorySyncStatus = "同步失败:iCloud 不可用(请检查是否登录并启用 iCloud Drive)"
                CoreDiagLog.log("historySync", "失败: iCloud 容器目录不可用")
                return
            }
            self.lastHistorySyncAt = Date()
            let merged = self.history.applyCloudMerge(cloudRecords: result.cloudRecords)
            let latestRecords = self.history.records
            let latestDeletions = self.history.deletionTombstones
            let push = await Task.detached(priority: .utility) {
                CloudHistorySync.pushAll(latestRecords, deletions: latestDeletions)
            }.value
            var parts: [String] = []
            if merged.deferred { parts.append("本机历史暂时无法读取,本轮云端内容已缓存,恢复后自动合并") }
            if merged.inserted > 0 { parts.append("合并 \(merged.inserted) 条") }
            if merged.adoptedFinal > 0 { parts.append("更新最终稿 \(merged.adoptedFinal) 条") }
            if merged.removed > 0 { parts.append("同步删除 \(merged.removed) 条") }
            if push.written > 0 { parts.append("写入 \(push.written) 条") }
            if push.failed > 0 { parts.append("写入失败 \(push.failed) 条") }
            if result.pendingDownload > 0 { parts.append("\(result.pendingDownload) 条云端下载中") }
            if parts.isEmpty { parts.append("无新内容") }
            self.lastHistorySyncStatus = "上次同步 \(Self.syncTimeFormatter.string(from: Date())) · "
                + parts.joined(separator: " · ")
            CoreDiagLog.log("historySync",
                "完成: 云端可读 \(result.cloudFiles) 条, 合并新增 \(merged.inserted), "
                + "更新最终稿 \(merged.adoptedFinal), 写入 \(push.written), "
                + "写入失败 \(push.failed), 待下载 \(result.pendingDownload)")
            self.isHistorySyncing = false
        }
    }

    private static let syncTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 设置页「全量上传本机历史」:整体重推(覆盖写同名文件),异步 + 状态反馈。
    func pushAllHistoryToCloud() {
        guard settings.iCloudSyncEnabled else {
            lastHistorySyncStatus = "同步未开启"
            return
        }
        guard !isHistorySyncing else { return }
        isHistorySyncing = true
        lastHistorySyncStatus = "正在上传全部历史…"
        let records = history.records
        let deletions = history.deletionTombstones
        CoreDiagLog.log("historySync", "全量上传开始 \(records.count) 条")
        Task { [weak self] in
            let push = await Task.detached(priority: .utility) { () -> CloudHistorySync.PushResult? in
                guard CloudHistorySync.isAvailable else { return nil }
                return CloudHistorySync.pushAll(records, deletions: deletions)
            }.value
            guard let self else { return }
            self.isHistorySyncing = false
            if let push, push.succeeded {
                self.lastHistorySyncAt = Date()
                self.lastHistorySyncStatus = "上次同步 \(Self.syncTimeFormatter.string(from: Date())) · 已上传 \(records.count) 条"
            } else {
                self.lastHistorySyncStatus = push == nil
                    ? "同步失败:iCloud 不可用(请检查是否登录并启用 iCloud Drive)"
                    : "同步失败:iCloud 写入失败 \(push?.failed ?? 0) 条"
            }
            CoreDiagLog.log("historySync", push?.succeeded == true
                ? "全量上传完成 \(records.count) 条"
                : "全量上传失败: iCloud 不可用或写入失败 \(push?.failed ?? 0) 条")
        }
    }

    /// 推送单条记录到云端(新增/编辑后调用);文件写入移出 MainActor。
    func cloudPush(id: UUID) {
        guard settings.iCloudSyncEnabled,
              let r = history.records.first(where: { $0.id == id }) else { return }
        cloudPushDetached(r)
    }

    /// 删除历史并传播墓碑。延迟数秒给未来可能加入的撤销交互留出窗口；若期间同 UUID
    /// 被恢复，HistoryStore 会移除墓碑，本任务不会写云端删除。
    func deleteHistory(id: UUID) {
        history.delete(id: id)
        guard settings.iCloudSyncEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let deletedAt = self.history.deletionTombstones[id] else { return }
            await Task.detached(priority: .utility) {
                _ = CloudHistorySync.pushDeletion(id: id, deletedAt: deletedAt)
            }.value
        }
    }

    func clearHistory() {
        history.clearAll()
        if settings.iCloudSyncEnabled { syncHistoryFromCloud() }
    }

    /// iCloud 镜像目录写入也可能等待文件协调,统一移出 MainActor。
    private func cloudPushDetached(_ record: DictationRecord) {
        Task.detached(priority: .utility) { CloudHistorySync.push(record) }
    }

    /// 防抖(5s)触发一轮词典 + 纠错对跨设备同步;失败静默重试,不打扰用户。
    /// 触发点:启动、回前台、词典编辑保存后、挖掘出新纠错对后。
    func scheduleDictionarySync(reason: String) {
        guard settings.dictionarySyncEnabled else {
            lastDictionarySyncStatus = "词典同步未开启"
            return
        }
        CoreDiagLog.log("dictSync", "计划同步 reason=\(reason)")
        dictionaryRetryTask?.cancel()
        dictionaryRetryAttempt = 0
        lastDictionarySyncStatus = dictionarySyncRunning ? "同步中，新修改已保存在本机，随后继续同步" : "本机已保存，等待同步"
        dictionarySyncDebounceTask?.cancel()
        dictionarySyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runDictionarySync()
        }
    }

    /// 立即触发一轮同步,跳过 5s 防抖——供词典窗口的"立即同步"按钮使用:用户刚在其它
    /// 设备上删了一批词、想马上把这次删除(墓碑)推上云端时,不想等自动防抖窗口。
    @Published private(set) var recleaningRecordID: UUID?
    @Published private(set) var cleanupRetryMessages: [UUID: String] = [:]

    func retryCleanup(record: DictationRecord) async {
        guard recleaningRecordID == nil, !record.rawText.isEmpty else { return }
        recleaningRecordID = record.id
        cleanupRetryMessages[record.id] = nil
        defer { recleaningRecordID = nil }
        do { try await settings.prepareRelaySession() }
        catch { cleanupRetryMessages[record.id] = error.localizedDescription; return }
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections, blocked: settings.blockedCorrectionSources)
        let route = DictationPolicy.cleanupPromptRoute(recordingDuration: record.recordingDuration ?? 0,
            transcript: record.rawText, fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds,
            forceShortPrompt: settings.cleanupLevel == .light)
        let prompt = PromptBuilder.buildDictation(route: route, customInstruction: settings.customPrompt,
            dictionary: settings.dictionaryWords, corrections: corrections)
        let service = CleanupService(baseURL: settings.activeLLMBaseURL, apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
        let raw = record.rawText
        let operation: @Sendable () async -> String? = {
            try? await service.clean(raw: raw, systemPrompt: prompt, forbidsNewNumbers: route == .homophoneOnly)
        }
        guard let response = await DictationPolicy.withTimeout(operation: operation), let response,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cleanupRetryMessages[record.id] = "整理未完成，原有文字已保留，可稍后重试"
            return
        }
        let clean = ManualCorrections.apply(to: response, pairs: corrections)
        guard history.replaceCleanup(expected: record, cleanText: clean) else {
            cleanupRetryMessages[record.id] = "记录已变化，本次结果未覆盖现有内容"
            return
        }
        cleanupRetryMessages[record.id] = record.finalText == nil ? "整理完成" : "整理完成，保留你的手动编辑稿"
        refreshAutoDictionary()
        if settings.iCloudSyncEnabled, let updated = history.records.first(where: { $0.id == record.id }) {
            Task.detached(priority: .utility) { CloudHistorySync.push(updated) }
        }
    }

    var dictionaryBackup: DictionaryBackup {
        DictionaryBackup(manual: settings.manualDictionaryWords, auto: settings.autoDictionaryWords,
            corrections: DictionarySyncCoordinator.effectiveCorrections(records: history.records,
                manual: settings.manualCorrections, blocked: settings.blockedCorrectionSources, limit: Int.max),
            blockedWords: settings.blockedDictionaryWords.sorted(),
            blockedCorrections: settings.blockedCorrectionSources.sorted())
    }

    @discardableResult
    func importDictionaryBackup(_ backup: DictionaryBackup) -> String {
        let preview = backup.preview(mergingInto: dictionaryBackup)
        let merged = preview.merged
        settings.userDictionaryRaw = merged.manual.joined(separator: "\n")
        settings.autoDictionaryRaw = merged.auto.joined(separator: "\n")
        settings.dictionaryBlocklistRaw = merged.blockedWords.joined(separator: "\n")
        settings.correctionsBlocklistRaw = merged.blockedCorrections.joined(separator: "\n")
        settings.manualCorrectionsRaw = merged.corrections.map { "\($0.source)\t\($0.target)" }.joined(separator: "\n")
        scheduleDictionarySync(reason: "词典备份导入")
        return "已导入 \(preview.added) 项，保留本机冲突项 \(preview.conflicts) 项"
    }

    func syncDictionaryNow() {
        guard settings.dictionarySyncEnabled else {
            lastDictionarySyncStatus = "词典同步未开启"
            return
        }
        CoreDiagLog.log("dictSync", "计划同步 reason=手动")
        dictionarySyncDebounceTask?.cancel()
        dictionaryRetryTask?.cancel()
        dictionaryRetryAttempt = 0
        Task { await runDictionarySync() }
    }

    /// 实际执行一轮同步:纯值快照进 Task.detached(iCloud 文件 I/O 可能等待,绝不能占用
    /// MainActor),合并结果回 MainActor 应用回 Settings。
    @Published private(set) var dictionarySyncRunning = false
    @Published private(set) var lastDictionarySyncDate: Date? = UserDefaults.standard.object(forKey: "dictionary.lastSuccessfulSync") as? Date
    private var dictionaryRetryTask: Task<Void, Never>?
    private var dictionaryRetryAttempt = 0

    func cancelDictionarySync() {
        dictionarySyncDebounceTask?.cancel()
        dictionaryRetryTask?.cancel()
        dictionarySyncRequested = false
        lastDictionarySyncStatus = "词典同步未开启，本机内容已保留"
    }

    private func retryDictionarySync(reason: String) {
        guard settings.dictionarySyncEnabled,
              let delay = DictionarySyncRetry.delay(afterFailures: dictionaryRetryAttempt) else {
            lastDictionarySyncStatus = reason + "，本机内容已保留，请稍后点立即同步"
            return
        }
        dictionaryRetryAttempt += 1
        lastDictionarySyncStatus = reason + "，将在 \(Int(delay)) 秒后重试"
        dictionaryRetryTask?.cancel()
        dictionaryRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.settings.dictionarySyncEnabled else { return }
            self.dictionaryRetryTask = nil
            await self.runDictionarySync()
        }
    }
    private var dictionarySyncRequested = false

    private func runDictionarySync() async {
        guard settings.dictionarySyncEnabled else { cancelDictionarySync(); return }
        guard !dictionarySyncRunning else { dictionarySyncRequested = true; return }
        dictionaryRetryTask?.cancel()
        dictionarySyncRunning = true
        lastDictionarySyncStatus = "正在同步词典…"
        defer {
            dictionarySyncRunning = false
            if dictionarySyncRequested {
                dictionarySyncRequested = false
                if settings.dictionarySyncEnabled { Task { await self.runDictionarySync() } }
            }
        }
        let manual = settings.manualDictionaryWords
        let auto = settings.autoDictionaryWords
        let blocked = settings.blockedDictionaryWords
        let blockedCorrections = settings.blockedCorrectionSources
        let corrections = DictionaryMiner.correctionPairs(records: history.records,
                                                          blocked: blockedCorrections) + settings.manualCorrections
        let result = await Task.detached(priority: .utility) {
            DictionarySyncCoordinator.syncAndMerge(
                currentManual: manual, currentAuto: auto, currentBlocked: blocked, corrections: corrections,
                currentBlockedCorrections: blockedCorrections)
        }.value
        guard settings.dictionarySyncEnabled else { cancelDictionarySync(); return }
        guard case .success(let merged) = result else {
            if case .failure(.writeFailed) = result {
                retryDictionarySync(reason: "iCloud 写入失败")
            } else if case .failure(.remotePending) = result {
                retryDictionarySync(reason: "云端词典下载中")
            } else {
                retryDictionarySync(reason: "iCloud 暂不可用")
            }
            CoreDiagLog.log("dictSync", "同步失败: \(String(describing: result))")
            return
        }
        guard settings.dictionarySyncEnabled else { return }
        if manual != settings.manualDictionaryWords || auto != settings.autoDictionaryWords
            || blocked != settings.blockedDictionaryWords { dictionarySyncRequested = true }
        DictionarySyncCoordinator.apply(merged, to: settings, startingManual: manual, startingAuto: auto)
        dictionaryRetryAttempt = 0
        lastDictionarySyncDate = Date()
        UserDefaults.standard.set(lastDictionarySyncDate, forKey: "dictionary.lastSuccessfulSync")
        lastDictionarySyncStatus = "已同步 · 词典 \(settings.dictionaryWords.count) · 纠错 \(merged.corrections.count)"
        CoreDiagLog.log("dictSync", "已应用合并结果: \(lastDictionarySyncStatus)")
    }

    private func scheduleOverlayHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { await MainActor.run { self?.overlay?.hide() } }
        }
    }

    /// 完成反馈保持可感知但不惊扰。系统总音量仍由用户控制；这里再将应用内完成音
    /// 压到较低相对音量，且不改变录音开始音和错误告警音。
    private func playCompletionSound() {
        guard let sound = NSSound(named: "Purr") else { return }
        sound.volume = 0.18
        sound.play()
    }

    /// 重算自动词典(口述完成、历史编辑后调用;全量重算,毫秒级)
    func refreshAutoDictionary() {
        let auto = DictionaryMiner.mine(
            records: history.records,
            manual: Set(settings.manualDictionaryWords),
            blocked: settings.blockedDictionaryWords)
        let updated = auto.joined(separator: "\n")
        if settings.autoDictionaryRaw != updated { settings.autoDictionaryRaw = updated }
        scheduleDictionarySync(reason: "自动词典/纠错对刷新") // 覆盖"挖掘出新纠错对后"这一触发点
    }

    /// 用当前整理设置重新整理一段 ASR 原文。
    /// 供历史窗口"重新整理"按钮:拿过往录音的原文测试新版整理效果,不改动原记录。
    /// 使用原录音时长与列举信号选择单次 Prompt，和首次整理/重试共用规则。
    func reclean(raw: String, recordingDuration: TimeInterval = 0) async -> String {
        do { try await settings.prepareRelaySession() }
        catch { return raw }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                 apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        let route = DictationPolicy.cleanupPromptRoute(
            recordingDuration: recordingDuration, transcript: text,
            fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds,
            forceShortPrompt: settings.cleanupLevel == .light)
        let base = PromptBuilder.buildDictation(route: route,
                                       customInstruction: settings.customPrompt,
                                       dictionary: settings.dictionaryWords,
                                       corrections: corrections)
        let response = await DictationPolicy.withTimeout {
            try? await llm.cleanStream(raw: text, systemPrompt: base,
                forbidsNewNumbers: route == .homophoneOnly) { _ in }
        }
        let cleaned = (response ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned?.isEmpty == false ? cleaned! : text)
    }

    /// 浮窗立即关闭(浮窗上的关闭按钮)
    func dismissOverlay() {
        hideTask?.cancel()
        overlay?.hide()
    }

    /// 鼠标悬停浮窗时暂停自动退出,移开后重新计时 3 秒
    func overlayHoverChanged(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
        } else if status == .idle {
            scheduleOverlayHide(after: 3)
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Accessibility 权限:全局热键监听 + 粘贴模拟都需要
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// 外观(跟随系统/浅色/深色)全局生效:设 `NSApp.appearance` 而不是逐窗口
    /// `.preferredColorScheme`,因为 CompareLab/BatchBench/悬浮 HUD 都是独立 NSWindow/NSPanel
    /// (非 SwiftUI Window Scene),只有应用级覆盖能一次性级联到全部窗口——包括菜单栏面板。
    /// `NSWindow.appearance`/`NSApplication.appearance` 默认 nil = 跟随上级,项目内没有任何
    /// 窗口单独设置过 appearance,因此这里设置一次即对全部现存与后续新建窗口生效。
    /// Theme 里的 NSColor 用 dynamicProvider 惰性求值,窗口 effectiveAppearance 变化后重绘
    /// 即自动取新值,不需要遍历窗口手动刷新背景色。由 SettingsView 的外观 Picker 在
    /// `.onChange` 里调用,即时生效、无需重启。
    func applyAppearance() {
        switch settings.appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - A/B 对比模式

    /// 双识别 + 双整理,各自计时,结果进对比实验室窗口;不自动插入
    private func finishCompare(wav: Data) async {
        let stopAt = Date()
        let recordingDuration = max(0, stopAt.timeIntervalSince(recordingStartedAt))
        var run = CompareRun()

        // 两路识别并发收尾(计时口径:停止说话 → 各自终稿)
        let sessA = streamSession; streamSession = nil
        let sessB = streamSessionB; streamSessionB = nil
        let rtB = openaiStreamB; openaiStreamB = nil
        let qwenB = qwenStreamB; qwenStreamB = nil
        let startErrorA = streamStartErrorA; streamStartErrorA = nil
        let startErrorB = streamStartErrorB; streamStartErrorB = nil
        async let ra = Self.finishTimed(sessA, label: "识别 A(主配置)", since: stopAt,
                                        startError: startErrorA)
        let asrBProvider = settings.asrBProvider
        let asrBBaseURL = settings.activeBatchASRBBaseURL
        let asrBKey = settings.activeBatchASRBKey
        let asrBModel = settings.activeBatchASRBModel
        let asrBPrompt = settings.activeBatchASRBPrompt
        let qwenBModel = settings.qwenBModel
        // B 路:OpenAI 流式(gpt-realtime-whisper)→ 尾延迟(与 A 同口径);否则 REST 整段
        async let rb = Self.finishASRB(
            rtB: rtB, qwenB: qwenB, sessB: sessB, since: stopAt, startError: startErrorB,
            wav: wav, provider: asrBProvider, baseURL: asrBBaseURL,
            apiKey: asrBKey, model: asrBModel, prompt: asrBPrompt,
            qwenModel: qwenBModel)
        run.asrA = await ra
        run.asrB = await rb

        // 各走完整链路:整理 A 吃识别 A 稿、整理 B 吃识别 B 稿。
        // A 稿(A 失败退 B,再退整段兜底)
        var rawA = run.asrA?.error == nil ? (run.asrA?.text ?? "") : ""
        if rawA.isEmpty { rawA = run.asrB?.error == nil ? (run.asrB?.text ?? "") : "" }
        if rawA.isEmpty {
            rawA = (try? await runASR(wav: wav)) ?? "" // 双路都失败,整段兜底
        }
        guard !rawA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveText = ""
            setError("没有识别到内容")
            compareRun = run
            return
        }
        // B 稿 = 识别 B 稿;B 无结果时退回 A 稿,保证整理 B 仍有输入可比
        var rawB = run.asrB?.error == nil ? (run.asrB?.text ?? "") : ""
        if rawB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rawB = rawA }
        let cleanupRawA = rawA
        let cleanupRawB = rawB

        // 两路整理并发；各自按自己的 ASR 稿判断成组列举信号，避免其中一路漏词时
        // 错误地替另一路选择 prompt。没有列举信号时仍按真实录音时长路由。
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        let cleanupRouteA = DictationPolicy.cleanupPromptRoute(
            recordingDuration: recordingDuration,
            transcript: cleanupRawA,
            fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds)
        let cleanupRouteB = DictationPolicy.cleanupPromptRoute(
            recordingDuration: recordingDuration,
            transcript: cleanupRawB,
            fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds)
        let promptA = PromptBuilder.buildDictation(
            route: cleanupRouteA, customInstruction: settings.customPrompt,
            dictionary: settings.dictionaryWords, corrections: corrections)
        let promptB = PromptBuilder.buildDictation(
            route: cleanupRouteB, customInstruction: settings.customPrompt,
            dictionary: settings.dictionaryWords, corrections: corrections)
        async let ca = Self.cleanTimed(
            label: "整理 A:\(settings.activeLLMModel)",
            base: settings.activeLLMBaseURL, key: settings.activeLLMKey,
            model: settings.activeLLMModel, raw: cleanupRawA, prompt: promptA)
        async let cb: EngineResult? = Self.cleanTimedOrNote(
            configured: settings.llmBConfigured, label: "整理 B:\(settings.llmBModel)",
            base: settings.llmBBaseURL, key: settings.llmBKey,
            model: settings.llmBModel, raw: cleanupRawB, prompt: promptB)
        run.cleanA = await ca
        run.cleanB = await cb

        compareRun = run
        lastRawText = rawA
        lastCleanText = run.cleanA?.text ?? rawA
        insertionNote = "对比完成,结果见「对比实验室」"
        manualCopyMode = false

        // 归档(用 A 路结果,保持四元组数据完整)
        let record = DictationRecord(
            id: UUID(), date: Date(), rawText: rawA, cleanText: lastCleanText, finalText: nil,
            audioFileName: settings.keepAudio ? await history.saveAudioAsync(wav) : nil)
        history.append(record)
        if settings.iCloudSyncEnabled { cloudPushDetached(record) }

        liveText = ""
        status = .idle
        playCompletionSound()
        scheduleOverlayHide(after: 2)

        if compareLab == nil { compareLab = CompareLabWindowController(appState: self) }
        compareLab?.show()
    }

    private static func finishTimed(_ session: VolcStreamingSession?, label: String,
                                    since: Date, startError: String? = nil) async -> EngineResult? {
        if let startError {
            var r = EngineResult(label: label)
            r.error = "流式建连失败: \(startError)"
            r.millis = Int(Date().timeIntervalSince(since) * 1000)
            return r
        }
        guard let session else { return nil }
        var r = EngineResult(label: label)
        do {
            r.text = try await session.finish()
            r.ttftMillis = session.firstPartialMillis
        } catch {
            session.cancel()
            r.error = error.localizedDescription
        }
        r.millis = Int(Date().timeIntervalSince(since) * 1000)
        return r
    }

    private static func finishCompareASRB(session: VolcStreamingSession?, since: Date,
                                          startError: String?, wav: Data,
                                          provider: ASRBProvider, baseURL: URL,
                                          apiKey: String, model: String,
                                          prompt: String?) async -> EngineResult? {
        switch provider {
        case .volcano:
            return await finishTimed(session, label: "识别 B(豆包)", since: since,
                                     startError: startError)
        case .openai:
            var r = EngineResult(label: "识别 B:\(model.isEmpty ? "(未填模型)" : model)")
            if let startError { r.error = "流式建连失败: \(startError)"; return r }
            guard !apiKey.isEmpty, !model.isEmpty else {
                r.error = "识别 B 未配置:请在设置填 OpenAI API Key 和模型 id"
                return r
            }
            let t0 = Date()
            do {
                r.text = try await OpenAICompatibleTranscription(
                    baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt)
                    .transcribe(wav: wav)
            } catch {
                r.error = error.localizedDescription
            }
            r.millis = Int(Date().timeIntervalSince(t0) * 1000)
            return r
        case .zenmux:
            var r = EngineResult(label: "识别 B:MiMo-V2.5-ASR (ZenMux)")
            guard !apiKey.isEmpty, !model.isEmpty else {
                r.error = "识别 B 未配置:请在设置填入 ZenMux API Key"
                return r
            }
            let t0 = Date()
            do {
                r.text = try await ZenMuxTranscription(
                    baseURL: baseURL, apiKey: apiKey, model: model)
                    .transcribe(wav: wav)
            } catch {
                r.error = error.localizedDescription
            }
            r.millis = Int(Date().timeIntervalSince(t0) * 1000)
            return r
        case .qwen:
            var r = EngineResult(label: "识别 B:千问(未建立会话)")
            r.error = startError.map { "千问流式建连失败: \($0)" }
                ?? "千问识别 B 未配置或未建立实时会话"
            r.millis = Int(Date().timeIntervalSince(since) * 1000)
            return r
        }
    }

    /// 是否为 OpenAI Realtime 流式识别模型(容忍 realtime / real-time / 显示名等写法)。
    static func isRealtimeASRModel(_ raw: String) -> Bool {
        let s = raw.lowercased()
        return s.contains("realtime") || s.contains("real-time") || s.contains("real time")
    }

    /// 把用户可能填的显示名(如 "GPT Real-time Whisper")归一成合法模型 id。
    static func canonicalRealtimeModel(_ raw: String) -> String {
        let s = raw.lowercased()
        if isRealtimeASRModel(raw), s.contains("whisper") { return "gpt-realtime-whisper" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 探测某个 OpenAI 兼容端点的可达性 + Key 有效性(GET /models)。用于对比 B 排查。
    static func probeOpenAI(_ label: String, baseURL: URL, apiKey: String) async -> String {
        guard !apiKey.isEmpty else { return "\(label):未填 API Key" }
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 { return "\(label):✅ 连通(HTTP 200,网络与 Key 均可用)" }
            let body = String(data: data, encoding: .utf8)?.prefix(140) ?? ""
            return "\(label):⚠️ HTTP \(code) \(body)"
        } catch {
            return "\(label):❌ \(error.localizedDescription)(多为网络到 OpenAI 不通)"
        }
    }

    /// 对 `/audio/transcriptions` 做一次真实的极短静音 WAV 请求。
    /// ZenMux 的订阅模型不一定出现在公开 `/models` 列表中,所以真实推理才是有效诊断。
    static func probeAudioTranscription(baseURL: URL, apiKey: String, model: String) async -> String {
        guard !apiKey.isEmpty, !model.isEmpty else { return "识别 B(ZenMux MiMo):未填模型或 API Key" }
        let silence = Recorder.wav(pcm: Data(count: 32_000), sampleRate: 16_000, channels: 1)
        do {
            _ = try await ZenMuxTranscription(
                baseURL: baseURL, apiKey: apiKey, model: model)
                .transcribe(wav: silence)
            return "识别 B(ZenMux MiMo):✅ 真实转写请求成功"
        } catch {
            return "识别 B(ZenMux MiMo):❌ \(error.localizedDescription)"
        }
    }

    /// 用与正式整理相同的参数,对 LLM B 模型做一次真实最小调用,暴露模型级错误(如 reasoning_effort 不支持、模型无权限)。
    static func probeLLMChat(baseURL: URL, apiKey: String, model: String) async -> String {
        guard !apiKey.isEmpty, !model.isEmpty else { return "整理 B 模型:未填模型或 Key" }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"; req.timeoutInterval = 25
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["model": model, "messages": [["role": "user", "content": "回复 ok"]]]
        let m = model.lowercased()
        if m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            payload["reasoning_effort"] = "none"
        } else {
            payload["temperature"] = 0.2
        }
        if m.contains("qwen") { payload["enable_thinking"] = false }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 { return "整理 B 模型(\(model)):✅ 真实调用成功" }
            let body = String(data: data, encoding: .utf8)?.prefix(220) ?? ""
            return "整理 B 模型(\(model)):⚠️ HTTP \(code) \(body)"
        } catch {
            return "整理 B 模型(\(model)):❌ \(error.localizedDescription)"
        }
    }

    /// 千问 ASR B 真实 WebSocket 握手 + session.update 测试,不发送麦克风数据。
    static func probeQwenASR(wsURL: URL, apiKey: String, model: String) async -> String {
        guard !apiKey.isEmpty, !model.isEmpty else { return "识别 B(千问):未填模型或 API Key" }
        let session = QwenRealtimeASRSession(baseURL: wsURL, apiKey: apiKey, model: model) { _ in }
        do {
            try await session.start()
            session.cancel()
            return "识别 B(千问 \(model)):✅ WebSocket 握手与会话配置成功"
        } catch {
            session.cancel()
            return "识别 B(千问 \(model)):❌ \(error.localizedDescription)"
        }
    }

    /// B 路 ASR 收尾分派:有 OpenAI 流式会话走流式(尾延迟);否则走原批量路径。
    private static func finishASRB(rtB: OpenAIRealtimeSession?, qwenB: QwenRealtimeASRSession?,
                                   sessB: VolcStreamingSession?,
                                   since: Date, startError: String?, wav: Data,
                                   provider: ASRBProvider, baseURL: URL, apiKey: String,
                                   model: String, prompt: String?,
                                   qwenModel: String) async -> EngineResult? {
        if let qwenB {
            return await finishQwenB(qwenB, since: since, startError: startError, model: qwenModel)
        }
        if let rtB {
            return await finishRealtimeB(rtB, since: since, startError: startError, model: model)
        }
        return await finishCompareASRB(session: sessB, since: since, startError: startError,
                                       wav: wav, provider: provider, baseURL: baseURL,
                                       apiKey: apiKey, model: model, prompt: prompt)
    }

    /// 千问 Realtime 流式 B:直接收尾 Manual mode,计时口径=停止说话→千问终稿。
    private static func finishQwenB(_ session: QwenRealtimeASRSession, since: Date,
                                    startError: String?, model: String) async -> EngineResult? {
        var r = EngineResult(label: "识别 B:千问 \(model)")
        if let startError {
            r.error = "流式建连失败: \(startError)"
            r.millis = Int(Date().timeIntervalSince(since) * 1000)
            return r
        }
        do {
            r.text = try await session.finish()
            r.ttftMillis = session.firstPartialMillis
        } catch {
            r.error = error.localizedDescription
        }
        if r.error == nil, r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r.error = "识别 B 无结果 · \(session.diagnostics)"
        }
        r.millis = Int(Date().timeIntervalSince(since) * 1000)
        return r
    }

    /// OpenAI Realtime 流式 B:计时口径与 A 一致(停止说话→终稿的尾延迟)。
    private static func finishRealtimeB(_ session: OpenAIRealtimeSession, since: Date,
                                        startError: String?, model: String) async -> EngineResult? {
        var r = EngineResult(label: "识别 B:\(model)")
        if let startError {
            r.error = "流式建连失败: \(startError)"
            r.millis = Int(Date().timeIntervalSince(since) * 1000)
            return r
        }
        do {
            r.text = try await session.finish()
            r.ttftMillis = session.firstPartialMillis
        } catch {
            r.error = error.localizedDescription
        }
        // 无异常但也没识别到文字:把会话诊断塞进卡片(控制台另有 [RT] 全量日志)
        if r.error == nil, r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r.error = "识别 B \(session.diagnostics)"
        }
        r.millis = Int(Date().timeIntervalSince(since) * 1000)
        return r
    }

    private static func cleanTimed(label: String, base: URL, key: String, model: String,
                                   raw: String, prompt: String) async -> EngineResult {
        final class TTFTBox: @unchecked Sendable { var value: Int? }
        var r = EngineResult(label: label)
        let t0 = Date()
        let box = TTFTBox()
        do {
            r.text = try await CleanupService(baseURL: base, apiKey: key, model: model)
                .cleanStream(raw: raw, systemPrompt: prompt) { _ in
                    if box.value == nil { box.value = Int(Date().timeIntervalSince(t0) * 1000) }
                }
        } catch {
            r.error = error.localizedDescription
        }
        r.millis = Int(Date().timeIntervalSince(t0) * 1000)
        r.ttftMillis = box.value
        return r
    }

    /// 整理 B:未配置也返回一张带提示的卡片(避免"什么都不显示"无从排查)。
    private static func cleanTimedOrNote(configured: Bool, label: String, base: URL, key: String,
                                        model: String, raw: String, prompt: String) async -> EngineResult {
        guard configured else {
            var r = EngineResult(label: "整理 B:未配置")
            r.error = "整理 B 未配置:请在设置的「整理 A/B 对比」填模型 id 和 API Key"
            return r
        }
        return await cleanTimed(label: label, base: base, key: key, model: model, raw: raw, prompt: prompt)
    }

    /// Match iOS: cloud streaming, then full-audio cloud retry, then local recognition
    /// only when the installed OS and predownloaded language assets support it.
    private func runASR(wav: Data) async throws -> String {
        currentRecognitionSource = .cloud
        do { return try await cloudASR(wav: wav) }
        catch {
            guard #available(macOS 26.0, *), OnDeviceTranscriber.isSupported,
                  await OnDeviceTranscriber.isReady,
                  let fallback = try? await OnDeviceTranscriber().transcribe(wav: wav),
                  !fallback.isEmpty else { throw error }
            currentRecognitionSource = .onDevice
            CoreDiagLog.log("asr", "云端识别失败，改用端侧兜底")
            return fallback
        }
    }

    /// 离线兜底稿的网络恢复路径。失败不改动原记录，也绝不覆盖用户编辑的 finalText。
    func recognizeWithCloudAgain(record: DictationRecord) async {
        guard recloudingRecordID == nil else { return }
        guard let audioURL = history.audioURL(for: record), let wav = try? Data(contentsOf: audioURL) else {
            lastHistorySyncStatus = "原音已不在本机，无法重新识别"
            return
        }
        recloudingRecordID = record.id
        defer { recloudingRecordID = nil }
        do {
            let raw = try await cloudASR(wav: wav)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastHistorySyncStatus = "云端没有识别到内容"
                return
            }
            let duration = max(0, Double(max(0, wav.count - 44)) / 32_000.0)
            let corrections = DictionarySyncCoordinator.effectiveCorrections(
                records: history.records, manual: settings.manualCorrections,
                blocked: settings.blockedCorrectionSources)
            let cleanupRoute = DictationPolicy.cleanupPromptRoute(
                recordingDuration: duration,
                transcript: raw,
                fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds,
                forceShortPrompt: settings.cleanupLevel == .light)
            let prompt = PromptBuilder.buildDictation(
                route: cleanupRoute,
                customInstruction: settings.customPrompt,
                dictionary: settings.dictionaryWords,
                corrections: corrections)
            let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                     apiKey: settings.activeLLMKey,
                                     model: settings.activeLLMModel)
            let cleaned = (try? await llm.clean(raw: raw, systemPrompt: prompt,
                                                forbidsNewNumbers: cleanupRoute == .homophoneOnly)) ?? raw
            let finalClean = ManualCorrections.apply(
                to: cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? raw : cleaned,
                pairs: corrections)
            history.replaceRecognition(id: record.id, rawText: raw, cleanText: finalClean)
            refreshAutoDictionary()
            cloudPush(id: record.id)
            lastHistorySyncStatus = "已用云端重新识别"
        } catch {
            lastHistorySyncStatus = "云端重新识别失败：\(error.localizedDescription)"
        }
    }

    /// 云端整段识别。豆包路径使用与 iOS 同一主识别配置，不在用户等待时串行探测
    /// 其它端点。
    private func cloudASR(wav: Data) async throws -> String {
        try await settings.prepareRelaySession()
        if settings.usesWorkerRelay {
            let corrections = DictionarySyncCoordinator.effectiveCorrections(
                records: history.records, manual: settings.manualCorrections,
                blocked: settings.blockedCorrectionSources)
            return try await VolcEngineASR(
                wsURL: settings.networkRoute.asrURL!, appId: "", accessToken: "",
                resourceId: settings.volcResourceId,
                hotwordsContext: settings.hotwordsContext(corrections: corrections, recentRecords: history.records),
                outputChineseVariant: settings.outputChineseVariant,
                protocolKind: .nostream, bearerToken: settings.activeWorkerToken).transcribe(wav: wav)
        }
        switch settings.asrProvider {
        case .openai:
            return try await OpenAICompatibleTranscription(
                baseURL: settings.asrBaseURL, apiKey: settings.asrKey, model: settings.asrModel)
                .transcribe(wav: wav)
        case .volcano:
            guard let url = settings.primaryASRWsURL else {
                throw NSError(domain: "ASR", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "请先在设置里配置豆包识别服务"])
            }
            let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
            return try await VolcEngineASR(
                wsURL: url, appId: settings.volcAppId, accessToken: settings.volcAccessToken,
                resourceId: settings.volcResourceId,
                hotwordsContext: settings.hotwordsContext(corrections: corrections,
                                                          recentRecords: history.records),
                outputChineseVariant: settings.outputChineseVariant
            ).transcribe(wav: wav)
        }
    }

    /// 出错统一处理:状态 + 提示音 + 系统通知(错误全文可在菜单面板查看)
    private func setError(_ msg: String) {
        status = .error(msg)
        overlay?.show()
        scheduleOverlayHide(after: 12)
        NSSound(named: "Basso")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Shall We Talk 出错"
        content.body = msg
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 热键或按钮触发:开始/结束一次口述
    func toggle() {
        switch status {
        case .idle, .error:
            start()
        case .recording:
            Task { await finish() }
        case .processing:
            break // 处理中忽略,防止连击
        }
    }

    /// macOS P0：对历史记录说出修改要求，调用与 iOS 相同的 EditPass/安全判定，而非把
    /// 修改指令误送入普通整理 prompt。P1 的“任意 App 选中文本”需单独处理 AX 选区，留待后续。
    func beginVoiceEdit(_ record: DictationRecord) {
        guard status == .idle else { return }
        voiceEditTarget = (record.id, record.finalText ?? record.cleanText)
        voiceEditStatus = "请说出对该记录的修改要求…"
        start()
    }

    func undoLastVoiceEdit() {
        guard let last = lastVoiceEdit else { return }
        guard history.undoLastRevision(id: last.id) else {
            voiceEditStatus = "正文已有后续编辑，未撤销旧版本"
            return
        }
        cloudPush(id: last.id); lastVoiceEdit = nil; voiceEditStatus = "已撤销语音修改"
    }

    private func start() {
        guard status != .recording, status != .processing else { return }
        // Capture before any authorization wait or our own floating UI appears.
        let frontmost = NSWorkspace.shared.frontmostApplication
        recordingTargetApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmost
        if !settings.usesWorkerRelay { startRecording(); return }
        status = .processing
        insertionNote = "正在检查连接授权…"
        Task {
            do {
                try await settings.prepareRelaySession()
                startRecording()
            } catch {
                voiceEditTarget = nil
                setError(error.localizedDescription)
            }
        }
    }

    private func startRecording() {
        voiceEditDisplayRequestID = nil
        insertionDisplayRequestID = nil
        let recordingRequestID = UUID()
        recordingDisplayRequestID = recordingRequestID
        do {
            liveText = ""
            manualCopyMode = false
            streamingFellBack = false
            streamStartErrorA = nil
            streamStartErrorB = nil
            levelEnvelope = 0
            audioLevel = 0
            recordingStartedAt = Date()
            lastVoiceAt = Date()
            hasDetectedSpeech = false
            voiceActivity.reset()
            voiceActivity.onSpeechState = { [weak self] speaking in
                Task { @MainActor in
                    guard let self, self.recordingDisplayRequestID == recordingRequestID else { return }
                    self.ingestVoiceActivity(speaking)
                }
            }
            // Power Mode:起录瞬间的前台 App 决定这次口述在 ASR 终稿后怎么整理。
            let frontmost = FrontmostApp.current()
            activeCleanup = ResolvedCleanupSettings.resolve(
                global: settings.cleanupLevel,
                customInstruction: settings.customPrompt,
                profile: settings.appProfile(for: frontmost?.bundleID))
            if let frontmost, settings.appProfile(for: frontmost.bundleID) != nil {
                CoreDiagLog.log("cleanup", "Power Mode 命中 \(frontmost.name)(\(frontmost.bundleID))"
                    + " 力度=\(activeCleanup.level.rawValue) 跳过整理=\(activeCleanup.skipCleanup)")
            }
            recorder.onLevel = { [weak self] raw in
                Task { @MainActor in
                    guard let self, self.recordingDisplayRequestID == recordingRequestID else { return }
                    self.ingestAudioLevel(raw)
                }
            }
            CleanupService.prewarm(baseURL: settings.activeLLMBaseURL,
                warmupURL: settings.workerWarmupURL,
                authToken: settings.usesWorkerRelay ? settings.activeWorkerToken : nil)
            startStreamingSessionIfPossible() // 录音开始即建连,边说边识别
            try recorder.start()
            status = .recording
            hideTask?.cancel()
            overlay?.show()
            NSSound(named: "Pop")?.play() // 开始提示音
        } catch {
            voiceEditTarget = nil
            // Sessions are prepared before the microphone starts. If capture
            // fails, release them immediately rather than leaving empty sockets
            // alive until the next recording or the server's idle timeout.
            streamSession?.cancel(); streamSession = nil
            streamSessionB?.cancel(); streamSessionB = nil
            openaiStreamB?.cancel(); openaiStreamB = nil
            qwenStreamB?.cancel(); qwenStreamB = nil
            recorder.onChunk = nil
            recorder.onLevel = nil
            setError("录音启动失败: \(error.localizedDescription)")
            recordingDisplayRequestID = nil
        }
    }

    /// 豆包供应商:并行开启流式会话。失败不报错,静默退回"说完整段上传"模式
    private func startStreamingSessionIfPossible() {
        streamSession?.cancel()
        streamSession = nil
        streamSessionB?.cancel()
        streamSessionB = nil
        openaiStreamB?.cancel()
        openaiStreamB = nil
        qwenStreamB?.cancel()
        qwenStreamB = nil
        streamStartErrorA = nil
        streamStartErrorB = nil
        recorder.onChunk = nil
        // 未配置流式识别时也要给 VAD 供 PCM,否则语音判定收不到数据。
        recorder.onChunk = { [weak self] chunk in self?.voiceActivity.feed(chunk) }
        guard settings.usesWorkerRelay || settings.asrProvider == .volcano,
              let url = settings.primaryASRWsURL,
              settings.usesWorkerRelay ? !settings.activeWorkerToken.isEmpty
                : (!settings.volcAppId.isEmpty && !settings.volcAccessToken.isEmpty) else { return }

        // 主链路固定使用与 iOS 相同的 SeedASR 2.0 native nostream（流式输入）端点，
        // 不读取历史主听写端点偏好。
        let connectURL = url

        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)

        let session = VolcStreamingSession(
            wsURL: connectURL, appId: settings.usesWorkerRelay ? "" : settings.volcAppId,
            accessToken: settings.usesWorkerRelay ? "" : settings.volcAccessToken,
            resourceId: settings.volcResourceId,
            hotwordsContext: settings.hotwordsContext(corrections: corrections, recentRecords: history.records),
            outputChineseVariant: settings.outputChineseVariant,
            protocolKind: .nostream,
            bearerToken: settings.usesWorkerRelay ? settings.activeWorkerToken : nil,
            // bigmodel_nostream 只保证处理后的句级结果，不保证录音中的实时 partial。
            // 主链路只在 finish() 消费终稿，不把中途结果上屏或提前送入 LLM。
            onPartial: { _ in }
        )
        streamSession = session

        // 对比模式:同一路麦克风数据喂给两条识别会话;禁用分段整理保证计时公平
        var sessionB: VolcStreamingSession?
        if settings.compareModeEnabled {
            if settings.asrBProvider == .volcano,
               settings.asrBConfigured, let urlB = URL(string: settings.volcBWsURLString) {
                let b = VolcStreamingSession(
                    wsURL: urlB, appId: settings.volcBAppId,
                    accessToken: settings.volcBAccessToken,
                    resourceId: settings.volcBResourceId,
                    hotwordsContext: settings.hotwordsContext(corrections: corrections, recentRecords: history.records)
                ) { _ in }
                sessionB = b
                streamSessionB = b
                Task { [weak self] in
                    guard self?.streamSessionB === b else { return }
                    do {
                        try await b.start()
                    } catch {
                        b.cancel()
                        NSLog("Shall We Talk 对比识别 B 建连失败: \(error.localizedDescription)")
                        await MainActor.run {
                            guard let self, self.streamSessionB === b else { return }
                            self.streamSessionB = nil
                            self.streamStartErrorB = error.localizedDescription
                        }
                    }
                }
            }
            // B 路 OpenAI:模型名含 realtime → 用 WebSocket 流式(与 A 同为流式,公平);
            // 否则仍在 finishCompare 里走 REST 整段转写。
            if settings.asrBProvider == .openai, settings.asrBConfigured,
               Self.isRealtimeASRModel(settings.asrBModel) {
                let rt = OpenAIRealtimeSession(apiKey: settings.asrBKey,
                                               model: Self.canonicalRealtimeModel(settings.asrBModel),
                                               language: "zh") { _ in }   // 主语言中文(英文混说仍照常转写)
                openaiStreamB = rt
                Task { [weak self] in
                    guard self?.openaiStreamB === rt else { return }
                    do {
                        try await rt.start()
                    } catch {
                        rt.cancel()
                        NSLog("Shall We Talk OpenAI 流式识别 B 建连失败: \(error.localizedDescription)")
                        await MainActor.run {
                            guard let self, self.openaiStreamB === rt else { return }
                            self.openaiStreamB = nil
                            self.streamStartErrorB = error.localizedDescription
                        }
                    }
                }
            }
            if settings.asrBProvider == .qwen, settings.asrBConfigured {
                let qwen = QwenRealtimeASRSession(
                    baseURL: settings.qwenBWsURL,
                    apiKey: settings.activeQwenBKey,
                    model: settings.qwenBModel,
                    language: "zh",
                    corpus: settings.qwenBCorpus
                ) { _ in }
                qwenStreamB = qwen
                Task { [weak self] in
                    guard self?.qwenStreamB === qwen else { return }
                    do {
                        try await qwen.start()
                    } catch {
                        qwen.cancel()
                        NSLog("Shall We Talk 千问流式识别 B 建连失败: \(error.localizedDescription)")
                        await MainActor.run {
                            guard let self, self.qwenStreamB === qwen else { return }
                            self.qwenStreamB = nil
                            self.streamStartErrorB = error.localizedDescription
                        }
                    }
                }
            }
            if settings.llmBConfigured {
                CleanupService.prewarm(baseURL: settings.llmBBaseURL)
            }
        }

        let rtB = openaiStreamB
        let qwenB = qwenStreamB
        recorder.onChunk = { [weak session, weak sessionB, weak rtB, weak qwenB, weak self] chunk in
            session?.feed(chunk)
            sessionB?.feed(chunk)
            rtB?.feed(chunk)
            qwenB?.feed(chunk)
            self?.voiceActivity.feed(chunk)   // VAD 与识别共用同一份 PCM
        }

        Task { [weak self] in
            guard self?.streamSession === session else { return }
            do {
                try await session.start()
            } catch {
                // 建连失败:撤掉流式,finish 时走整段兜底;明确标记,不静默
                NSLog("Shall We Talk 流式建连失败,本次将整段识别: \(error.localizedDescription)")
                session.cancel()
                await MainActor.run {
                    guard let self, self.streamSession === session else { return }
                    self.streamSession = nil
                    self.streamStartErrorA = error.localizedDescription
                    if !self.settings.compareModeEnabled {
                        // 与 iOS 一致：流式建连失败时只撤掉 ASR 会话，VAD 仍需继续拿 PCM。
                        self.recorder.onChunk = { [weak self] chunk in self?.voiceActivity.feed(chunk) }
                    }
                    self.streamingFellBack = true
                }
            }
        }
    }

    /// 音量包络:变大响应快(attack 0.4),回落稍慢(release 0.15);顺带做 VAD 静音检测
    /// VAD 的语音状态回调,与 `ingestAudioLevel` 的 RMS 分支互斥。
    private func ingestVoiceActivity(_ speaking: Bool) {
        guard status == .recording, speaking else { return }
        hasDetectedSpeech = true
        lastVoiceAt = Date()
    }

    private func ingestAudioLevel(_ raw: Float) {
        guard status == .recording else { return }
        let coeff: Float = raw > levelEnvelope ? 0.4 : 0.15
        levelEnvelope += (raw - levelEnvelope) * coeff
        audioLevel = levelEnvelope

        // VAD:说过话之后,持续静音超过阈值自动结束
        // 保守设计:开录前 1.5 秒不触发;从未检测到语音不触发(避免还没开口就被切)
        // 语音判定优先用 Silero VAD;模型不可用时退回固定 RMS 阈值,
        // 绝不能两边都不更新 lastVoiceAt,否则静音会一路累积到自动停录。
        if !voiceActivity.isAvailable, raw > 0.18 {
            hasDetectedSpeech = true
            lastVoiceAt = Date()
        }
        let silence = Date().timeIntervalSince(lastVoiceAt)

        // A/B 对比模式:测试需完整、可控的口述,禁用 VAD 自动停止,完全由手动结束控制
        // 半句话中间的停顿把静音预算放宽到 2.5 倍(2026-08-05,与 iOS 同一判定):
        // 思考下半句怎么说的停顿不该被当成说完了。
        if settings.vadEnabled, !settings.compareModeEnabled, hasDetectedSpeech,
           Date().timeIntervalSince(recordingStartedAt) > 1.5,
           DictationPolicy.shouldAutoStop(silence: silence,
                                          threshold: settings.vadSilenceSeconds,
                                          transcriptSoFar: liveText) {
            toggle() // 自动结束并进入识别整理
        }
    }

    private func finish() async {
        // 与 iOS 一致：VAD 的高频回调可能在状态翻转前重复请求停止，只允许一条收尾链路。
        guard status == .recording else { return }
        recordingDisplayRequestID = nil
        let wav = recorder.stop()
        recorder.onChunk = nil
        recorder.onLevel = nil
        levelEnvelope = 0
        audioLevel = 0 // 波形回到静态低幅
        status = .processing

        if settings.compareModeEnabled {
            await finishCompare(wav: wav)
            return
        }
        // 端到端延迟打点起点:录音停止的时刻,下面各阶段的 metrics 字段都以此为锚点,
        // 详见 LatencyMetrics 的口径说明。A/B 对比模式(finishCompare)有自己独立的
        // EngineResult 计时体系(供对比实验室展示),不复用这套普通链路的 metrics。
        let stopAt = Date()
        let recordingDuration = max(0, stopAt.timeIntervalSince(recordingStartedAt))
        let shouldArchiveAudio = settings.keepAudio && voiceEditTarget == nil
        // Start disk work now, but do not put its latency in front of ASR finish.
        // Success and failure both join this same task before persisting a record.
        let audioArchiveTask = Task { [history] in
            shouldArchiveAudio ? await history.saveAudioAsync(wav) : nil
        }
        let recordID = UUID()
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        var metrics = LatencyMetrics()
        currentRecognitionSource = .cloud
        var asrCompletionPath: ASRCompletionPath = .unidirectional
        var streamingDiagnostics: ASRStreamingWorkRecord?
        do {
            // 1. ASR：优先完成 native nostream 流式输入会话；失败退回整段上传。
            let raw: String
            if let session = streamSession {
                streamSession = nil
                do {
                    // session 本身现在就是 native nostream 流式输入连接（见 startStreamingSessionIfPossible），
                    // finish() 返回的已经是定稿,不需要再额外发一次复核请求。
                    let streamedFinal = try await session.finish()
                    guard !streamedFinal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw NSError(
                            domain: "ASR", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "nostream 会话返回空终稿"])
                    }
                    raw = streamedFinal
                    streamingDiagnostics = streamingWorkRecord(session: session, outcome: .completed)
                } catch {
                    session.cancel()
                    // 流式输入会话中途失败 → 用完整 WAV 重新识别。
                    NSLog("Shall We Talk 流式中途失败,退回整段识别: \(error.localizedDescription)")
                    streamingFellBack = true
                    streamingDiagnostics = streamingWorkRecord(
                        session: session, outcome: .fellBack,
                        fallbackReason: error.localizedDescription)
                    raw = try await runASR(wav: wav)
                    asrCompletionPath = currentRecognitionSource == .onDevice ? .onDevice : .wholeRecording
                }
            } else {
                let startError = streamStartErrorA
                let wasExpectedBatchPath = settings.asrProvider != .volcano
                streamingDiagnostics = streamingWorkRecord(
                    session: nil, outcome: startError == nil && wasExpectedBatchPath ? .unavailable : .fellBack,
                    fallbackReason: startError ?? (wasExpectedBatchPath ? "当前 ASR 服务未启用豆包流式会话" : "录音期间没有可用的流式会话"))
                raw = try await runASR(wav: wav)
                asrCompletionPath = currentRecognitionSource == .onDevice ? .onDevice : .wholeRecording
            }
            metrics.asrFinalMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            lastRawText = raw

            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "ASR", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "没有识别到内容"])
            }

            // 整段只有"嗯""呃"这类纯发声停顿:整理后必然为空,不该插入任何文字,
            // 也不值得为它发一次 LLM 请求。
            guard !DictationPolicy.isPureFilledPause(raw) else {
                CoreDiagLog.log("cleanup", "整段仅含纯发声停顿,跳过整理与插入 raw=\(raw.count)字")
                throw NSError(domain: "ASR", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "没有识别到内容"])
            }

            if let target = voiceEditTarget {
                await applyVoiceEdit(target: target, instruction: raw)
                return
            }

            // ASR 定稿中的成组列举信号优先于 10 秒阈值，路由到强化序号 prompt。
            let cleanupRoute = DictationPolicy.cleanupPromptRoute(
                recordingDuration: recordingDuration,
                transcript: raw,
                fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds,
                forceShortPrompt: activeCleanup.level == .light)

            // 2. LLM 整理。成组列举信号优先，否则以真实录音时长选择短/长 prompt。
            let meaningfulCount = DictationPolicy.meaningfulCharacterCount(raw)
            var clean = raw
            var cleanupStatus: CleanupStatus = .skipped
            let tokenBox = MillisBox()
            let usageBox = UsageBox()
            if activeCleanup.skipCleanup {
                // 该 App 的 Power Mode 声明不整理(终端、代码编辑器这类场景):直接用 ASR 原文。
                CoreDiagLog.log("cleanup", "Power Mode 声明跳过整理,直接使用 ASR 原文")
            } else if settings.redundantCleanupGateEnabled,
                      DictationPolicy.cleanupIsRedundant(raw, dictionaryWords: settings.dictionaryWords,
                          corrections: corrections, customInstruction: activeCleanup.customInstruction) {
                CoreDiagLog.log("cleanup", "空转守门员跳过本次整理")
            } else {
                // 与 iOS 主听写使用同一条调用结构：nostream 终稿后最多发一次 LLM 请求，
                // Power Mode 解析出的自定义指令对短、长和显式列举三条路由都生效。
                let prompt = PromptBuilder.buildDictation(
                    route: cleanupRoute,
                    customInstruction: activeCleanup.customInstruction,
                    dictionary: settings.dictionaryWords,
                    corrections: corrections)
                let llm = CleanupService(
                    baseURL: settings.activeLLMBaseURL, apiKey: settings.activeLLMKey,
                    model: settings.activeLLMModel)
                let firstPassStartedAt = Date()
                let displayRequestID = UUID()
                cleanupDisplayRequestID = displayRequestID
                cleanupStatus = .succeeded
                let operation: @Sendable () async -> String? = { [weak self] in
                    do {
                        return try await llm.cleanStream(raw: raw, systemPrompt: prompt, onFirstToken: {
                        if tokenBox.value == nil { tokenBox.value = Int(Date().timeIntervalSince(stopAt) * 1000) }
                    }, onUsage: { usageBox.value = $0 },
                                                forbidsNewNumbers: cleanupRoute == .homophoneOnly) { [weak self] partial in
                        Task { @MainActor in
                            guard let self, self.cleanupDisplayRequestID == displayRequestID else { return }
                            self.liveText = partial
                        }
                        }
                    } catch {
                        // Do not log response bodies, dictated text or credentials.
                        let failure = error as NSError
                        CoreDiagLog.log("cleanup", "request failed domain=\(failure.domain) code=\(failure.code) cancelled=\(Task.isCancelled)")
                        return nil
                    }
                }
                if let response = await DictationPolicy.withTimeout(operation: operation), let response, !response.isEmpty {
                    clean = response
                } else {
                    clean = raw
                    cleanupStatus = .failed
                    CoreDiagLog.log("cleanup", "cleanup unavailable: preserved original ASR text (request failure, empty response or deadline)")
                }
                cleanupDisplayRequestID = nil
                metrics.firstCleanupPass = cleanupPassMetrics(
                    startedAt: firstPassStartedAt, firstTokenMillis: tokenBox.value,
                    completedAt: Date(), usage: usageBox.value, stopAt: stopAt)
                let routeName: String
                switch cleanupRoute {
                case .homophoneOnly: routeName = "短口述单次整理"
                case .full: routeName = "长口述单次完整整理"
                case .explicitEnumeration: routeName = "显式列举强化整理"
                }
                CoreDiagLog.log(
                    "cleanup",
                    "\(routeName) duration=\(String(format: "%.1f", recordingDuration))s threshold=\(Int(settings.fullCleanupThresholdSeconds))s count=\(meaningfulCount)")
            }
            if clean.isEmpty { clean = raw }
            // 确定性替换兜底:纠错对已经喂过整理 prompt,但那是给模型的自然语言指令,
            // 是否严格执行、是否不区分大小写都不保证——
            // 整理失败时与 iOS 一样保留未经修改的原文；其他路径执行明确纠错对。
            if cleanupStatus != .failed {
                clean = ManualCorrections.apply(to: clean, pairs: corrections)
            }
            metrics.llmFirstTokenMillis = metrics.firstCleanupPass?.firstTokenMillis ?? tokenBox.value
            metrics.apply(usageBox.value)
            metrics.cleanupCompleteMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            logPromptCacheStats(metrics)
            logCleanupPassStats(metrics)
            lastCleanText = clean

            // 2.5 闪念胶囊路由:以"提醒我/记一下/待办"等开头 = 对电脑提的请求
            //     → 拆成待办条目入库,不插入正文
            var insertionPending = false
            var routedToTodo = false
            if IntentRouter.shouldCreateTodo(rawText: raw, cleanedText: clean) {
                let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                         apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
                let items = await IntentRouter.extractTodos(
                    from: clean, llm: llm, dictionary: settings.dictionaryWords)
                let plans = items.map { TodoDateResolver.resolve($0, spokenAt: recordingStartedAt) }
                let normalizedItems = zip(items, plans).map { text, plan in plan?.normalizedText ?? text }
                let added = todos.add(normalizedItems, sourceRecordID: recordID, sourceRawText: raw)
                enqueueCalendarUpdates(todos: added, plans: plans)
                lastCleanText = normalizedItems.joined(separator: "\n")
                insertionNote = "已存入待办(\(items.count) 条)"
                manualCopyMode = false
                routedToTodo = true
            }

            // 3. 结果去向三分支:
            //    a) 检测到文本输入框 → 插入,浮窗立即收起
            //    b) 没有输入框 → 醒目复制按钮,点击后立即收起
            //    c) 都没发生 → 3 秒后自动收起
            let trusted = AXIsProcessTrusted()
            let targetReady: Bool
            if !routedToTodo && autoInsert && trusted {
                overlay?.hide()
                targetReady = await TextInserter.prepareTarget(fallback: recordingTargetApp)
            } else {
                targetReady = false
            }
            CoreDiagLog.log("insertion", "enabled=\(autoInsert) trusted=\(trusted) todo=\(routedToTodo) targetReady=\(targetReady)")
            if routedToTodo {
                // 已入待办,不做任何插入/复制
            } else if autoInsert && trusted && targetReady {
                // fail-open:只有明确判定焦点是非文本控件才拦截,查不出一律插入
                switch TextInserter.checkFocusedElement() {
                case .notEditable(let role):
                    CoreDiagLog.log("insertion", "noneditable role=\(role)")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clean, forType: .string)
                    manualCopyMode = true
                    insertionNote = "焦点不是文本输入框(\(role))"
                case .editable, .unknown:
                    insertionPending = true
                    insertionNote = "正在插入光标处…"
                    manualCopyMode = false
                    insertionDisplayRequestID = recordID
                    TextInserter.insertAtCursor(clean) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.insertionDisplayRequestID == recordID else { return }
                            self.insertionDisplayRequestID = nil
                            CoreDiagLog.log("insertion", "result=\(String(describing: result))")
                            self.overlay?.show()
                            switch result {
                            case .verified:
                                self.insertionNote = "已插入光标处"
                                self.manualCopyMode = false
                                self.scheduleOverlayHide(after: 0.5)
                            case .directWriteIssuedUnverified:
                                self.insertionNote = "已尝试直接写入，无法确认；请检查目标输入框"
                                self.manualCopyMode = true
                            case .pasteIssuedUnverified:
                                self.insertionNote = ""
                                self.manualCopyMode = false
                                self.dismissOverlay()
                            case .failedToIssuePaste:
                                self.insertionNote = "自动插入失败，文字已保留在剪贴板"
                                self.manualCopyMode = true
                                self.scheduleOverlayHide(after: 5)
                            }
                        }
                    }
                }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clean, forType: .string)
                manualCopyMode = true
                insertionNote = !trusted ? "未授予辅助功能权限,请手动复制"
                    : (autoInsert ? "未找到输入目标，文字已复制" : "已复制到剪贴板")
            }
            if !insertionPending { overlay?.show() }

            // 4. 落库(四元组的前三项;finalText 由用户后续在历史里修改时补充)
            let archivedAudio = await audioArchiveTask.value
            metrics.totalMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            let record = DictationRecord(
                id: recordID, date: recordingStartedAt, rawText: raw, cleanText: clean, finalText: nil,
                audioFileName: archivedAudio, metrics: metrics,
                recognitionSource: currentRecognitionSource, asrCompletionPath: asrCompletionPath,
                streamingDiagnostics: streamingDiagnostics,
                cleanupStatus: cleanupStatus, recordingDuration: recordingDuration)
            history.append(record)
            if settings.iCloudSyncEnabled { cloudPushDetached(record) } // 增量上云
            refreshAutoDictionary() // 词典自动学习:常用专有词达到阈值自动入典

            status = .idle
            liveText = ""
            playCompletionSound()
            // 异步上屏必须等实际结果再决定提示与收起时机，不能在发出 Cmd-V 前假报成功。
            if !insertionPending { scheduleOverlayHide(after: 3) }
        } catch {
            // Async fallback must be evaluated before the synchronous record
            // initializer (and outside nil-coalescing's autoclosure).
            var failureAudio = await audioArchiveTask.value
            if failureAudio == nil, settings.keepAudio {
                failureAudio = await history.saveAudioAsync(wav)
            }
            history.append(DictationRecord(id: UUID(), date: stopAt, rawText: "", cleanText: "",
                audioFileName: failureAudio,
                recognitionFailure: error.localizedDescription))
            liveText = ""
            voiceEditTarget = nil
            setError("处理失败: \(error.localizedDescription)")
        }
    }

    private func applyVoiceEdit(target: (id: UUID, original: String), instruction: String) async {
        let displayRequestID = UUID()
        voiceEditDisplayRequestID = displayRequestID
        defer {
            if voiceEditDisplayRequestID == displayRequestID { voiceEditDisplayRequestID = nil }
            voiceEditTarget = nil
        }
        let service = CleanupService(baseURL: settings.activeLLMBaseURL, apiKey: settings.activeLLMKey,
                                     model: settings.activeLLMModel)
        do {
            let outcome = try await EditPass.run(original: target.original, instruction: instruction,
                                                  llm: service, dictionary: settings.dictionaryWords) { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.voiceEditDisplayRequestID == displayRequestID else { return }
                    self.liveText = partial
                }
            }
            switch outcome {
            case .applied(let text):
                let old = history.records.first(where: { $0.id == target.id })?.finalText
                guard history.pushRevisionIfUnchanged(id: target.id, instructionRaw: instruction,
                    before: target.original, after: text) else {
                    voiceEditStatus = "记录已更新或删除，未覆盖；请重新发起修改"
                    liveText = ""
                    status = .idle
                    return
                }
                refreshAutoDictionary(); cloudPush(id: target.id)
                lastVoiceEdit = (target.id, old)
                voiceEditStatus = "已语音修改，可撤销"
            case .flaggedLargeChange(let text):
                let old = history.records.first(where: { $0.id == target.id })?.finalText
                guard history.pushRevisionIfUnchanged(id: target.id, instructionRaw: instruction,
                    before: target.original, after: text) else {
                    voiceEditStatus = "记录已更新或删除，未覆盖；请重新发起修改"
                    liveText = ""
                    status = .idle
                    return
                }
                refreshAutoDictionary(); cloudPush(id: target.id)
                lastVoiceEdit = (target.id, old)
                voiceEditStatus = "已修改；改动幅度较大，请核对"
            case .noEdit: voiceEditStatus = "没有听清修改要求，原文未动"
            case .unchanged: voiceEditStatus = "没有检测到改动，原文未动"
            }
            lastCleanText = history.records.first(where: { $0.id == target.id })?.finalText ?? target.original
            status = .idle
        } catch { setError("语音修改失败：\(error.localizedDescription)") }
    }
}
