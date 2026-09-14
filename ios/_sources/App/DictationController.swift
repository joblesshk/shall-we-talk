import Foundation
import AVFoundation
import Combine
import UIKit
import os.log
import ShallWeTalkCore

/// 延迟打点用的线程安全小盒子:CleanupService.onFirstToken 在非 MainActor 上下文触发,
/// 需要一个可从任意上下文写入、finish() 结束前在 MainActor 上读回的容器。
/// 与 macOS AppState.cleanTimed 里的 TTFTBox 同一惯用法。
private final class MillisBox: @unchecked Sendable {
    var value: Int?
}

/// 流末 token 账单的跨并发域承接盒,与 `MillisBox` 同一模式。
/// 只在 SSE 结束时写一次,读取发生在同一个 await 之后,不存在竞争窗口。
private final class UsageBox: @unchecked Sendable {
    var value: CleanupService.Usage?
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

private func logCleanupPassStats(_ metrics: LatencyMetrics) {
    for (name, pass) in [("首轮整理", metrics.firstCleanupPass), ("结构化通读", metrics.structurePass)] {
        guard let pass else { continue }
        let rate = pass.promptCacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "未知"
        DiagLog.log("cleanup", "\(name) start=\(pass.startedMillis.map { "\($0)ms" } ?? "-") "
            + "first=\(pass.firstTokenMillis.map { "\($0)ms" } ?? "-") "
            + "end=\(pass.completedMillis.map { "\($0)ms" } ?? "-") "
            + "requests=\(pass.requestCount.map(String.init) ?? "-") "
            + "prompt=\(pass.promptTokens.map(String.init) ?? "-") "
            + "cached=\(pass.cachedPromptTokens.map(String.init) ?? "-")(\(rate))")
    }
}

/// 修改模式(applyEdit)诊断用:承接 EditPass 流式输出的最后一次增量(累计文本),
/// 与 `MillisBox`/`UsageBox` 同一模式。EditOutcome.unchanged/.noEdit 不带候选字符串,
/// 靠这个盒子在分类前把模型原始输出留一份下来记日志,否则复现"为什么没改动"时
/// 无从对照原文/指令/模型输出三者。
private final class TextBox: @unchecked Sendable {
    var value: String = ""
}

/// 整理请求的结果必须能区分“成功返回原文”与“请求失败后回退原文”。
/// 两者显示结果可能相同,但失败时历史记录要保留未经整理的 ASR 原文。
private enum CleanupAttempt: Sendable {
    case success(String)
    case failed
}

/// iOS 口述管线:与 macOS AppState 同构(流式识别 + 增量整理 + 停顿提交 + VAD)
/// 差异:结果不做系统粘贴模拟；键盘投递走 App Group，Action 投递同时保留剪贴板副本。
@MainActor
final class DictationController: ObservableObject {
    private var cleanupDisplayRequestID: UUID?
    static let shared = DictationController()

    enum Phase: Equatable { case idle, recording, processing, done, error(String) }

    /// 入口即意图:
    /// - standalone:App 内口述页 → 输出文字(触发词命中才转待办)
    /// - keyboard:键盘拉起(voicepen://record)→ 主要目的是输入,触发词命中才转待办
    /// - capture:快捷指令/操作按钮拉起(voicepen://capture)→ 复制整理稿;是否建待办
    ///   由 `actionForceTodo` 决定(Action Key 一律强制,「语音记录」捷径仍按触发词分流)
    /// - todoCapture:App 内待办页明确发起的口述 → 强制建待办
    enum LaunchMode { case standalone, keyboard, capture, todoCapture }

    /// 修改模式(语音二次修改-执行方略.md v2 §5)正在修改的目标。
    /// `recordID` 为 nil = 键盘态(P1):要改的文本是宿主输入框里键盘自己标住的内容,
    /// 不对应任何 `DictationRecord`,不落 `HistoryStore`。非 nil = 主 App 结果页(P0),
    /// 走版本栈 + 撤销。
    struct EditTarget: Equatable {
        let recordID: UUID?
        let baseText: String
    }

    /// 一次修改的展示态。`id` 每次新生成(而不是复用 `recordID`),让结果页 banner 的
    /// `.task(id:)` 在"同一条记录连续两次修改"时也能正确重新触发自动收起计时。
    struct EditOutcomeEntry: Equatable, Identifiable {
        let id = UUID()
        let recordID: UUID
        let outcome: EditOutcome
    }

    @Published var phase: Phase = .idle {
        didSet {
            if phase != .processing { processingStage = nil }
        }
    }
    @Published private(set) var processingStage: DictationProcessingStage?
    @Published var mode: LaunchMode = .standalone
    /// 本次 `.capture` 会话是否一律建待办(Action Key=true,「语音记录」捷径=false)。
    /// 只在起录那一刻由 `ActionCaptureRequestStore` 消费到的请求写入,会话期间不再改写。
    private var actionForceTodo = false
    private var shortcutResultSession = UUID()
    private var shortcutResultText: String?

    /// Keep the intent alive through recognition. Never return text from an older session.
    func stopActionCaptureReturningText() async throws -> String {
        let session = shortcutResultSession
        guard mode == .capture, phase == .recording || phase == .processing else {
            throw NSError(domain: "ShortcutCapture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "没有正在进行的语音输入。"])
        }
        if phase == .recording {
            _ = ActionCaptureSessionStore.consumeStopRequest()
            Task { await finish() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard shortcutResultSession == session else { break }
            if phase != .recording && phase != .processing {
                if let text = shortcutResultText, !text.isEmpty {
                    // Delivery is now owned by the system shortcut, not a later
                    // foreground retry that could overwrite a newer clipboard.
                    pendingClipboardCopy.clear()
                    shortcutClipboardMessage = "文字已返回快捷指令"
                    CaptureLiveActivityController.shared.complete(message: "文字已返回快捷指令")
                    phase = .done
                    return text
                }
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "ShortcutCapture", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "本次识别结果尚未就绪或识别失败，请稍后在记录中查看。"])
    }

    private let pendingClipboardCopy = PendingClipboardCopyStore()
    @Published private(set) var shortcutClipboardMessage: String?

    func retryShortcutClipboardCopyIfActive() {
        guard UIApplication.shared.applicationState == .active,
              phase != .recording, phase != .processing else { return }
        if let text = pendingClipboardCopy.retry(copy: PendingTextStore.copyToSystemPasteboard) {
            resultText = text
            shortcutClipboardMessage = "已复制，回到原输入框粘贴"
            phase = .done
            CaptureLiveActivityController.shared.complete(message: "已复制，回到原输入框粘贴")
            DiagLog.log("clipboard", "快捷指令前台补复制成功")
        }
    }
    @Published var liveText = ""
    @Published var resultText = ""
    @Published var audioLevel: Float = 0
    @Published var routedToTodo = false
    @Published var lastCloudSyncStatus = "未同步"
    @Published var lastDictionarySyncStatus = "未同步"
    /// 正在用云端重新识别的离线兜底记录;非 nil 时历史页对应行显示进度并禁用重复触发。
    @Published private(set) var recloudingRecordID: UUID?
    /// 修改模式(语音二次修改-执行方略.md v2)当前正在修改的记录;非 nil 时下一次
    /// 录音结束会走 `applyEdit`,不进入常规整理/待办路由。
    @Published private(set) var editingTarget: EditTarget?
    /// 上一次修改的结果,供结果页 banner 展示(成功/判定不出/无改动/大幅改动四态)。
    @Published private(set) var lastEditOutcome: EditOutcomeEntry?
    @Published private(set) var standbyEnabled = false
    @Published private(set) var standbyIsStarting = false
    @Published private(set) var standbyEndsAt: Date?
    @Published private(set) var standbyStatus = "未开启"
    /// 本轮待命已尝试的前台重建次数,`deactivateStandby` 时清零。
    private var standbyRebuildAttempts = 0
    /// 自动开启待命的重试任务;同一时刻只允许一个。
    private var standbyArmRetryTask: Task<Void, Never>?
    /// 后台跳过只记一条,避免 250ms 重试把轨迹刷满。
    private var loggedBackgroundSkip = false

    var fromKeyboard: Bool { mode == .keyboard }
    /// iOS 不允许冷后台进程新激活麦克风。Action Intent 用此值决定是否可以
    /// 不打开 App 直接恢复暖会话，还是必须先切到前台再开麦。
    var canResumeActionCaptureInBackground: Bool { canStartRecordingInBackground }

    /// 给 `StartTodoCaptureIntent` 用的**实时**捕捉状态。
    ///
    /// 意图此前只看跨进程的 `ActionCaptureSessionStore.isRecording`,而那个标记会被 VAD
    /// 自动停清掉(finish → clear)。2026-08-07 实测的表现是:用户说完停顿 4 秒,VAD 先把
    /// 录音停了,用户再按操作按钮想"停止",标记已是 false,于是被判成"开始新一段"——
    /// 新一段又撞上正在识别的上一段拿不到样本,触发前台重试,App 自己跳出来。
    /// 意图与 App 同进程,直接问对象最准,不必绕跨进程标记。
    var actionCaptureLiveState: (recording: Bool, processing: Bool) {
        (phase == .recording && mode == .capture, phase == .processing && mode == .capture)
    }

    /// 背景“能收到键盘命令”不等于“能在背景新建录音会话”。
    /// SCK / 纯音频待命都只在 Recorder 的预热引擎确实存活时才算数,
    /// 键盘点击这时才是“打开既有取样闸门”,可以从后台直接开录;
    /// 引擎不在,再多的后台调度资格也开不了新会话(§11.1 的 `!rec`)。
    private var canStartRecordingInBackground: Bool {
        if recorder.isHot { return true }
        if StandbyController.keepsRecorderHot { return false }
        return standbyEnabled && StandbyController.shared.isActive
    }

    let settings = MobileSettingsStore()
    let history = HistoryStore()
    let todos = TodoStore()

    private let recorder = Recorder()
    private var streamSession: VolcStreamingSession?
    /// 建连失败发生在异步任务中；保留到 stop 时写进本次本机工作记录，避免只留下
    /// "整段识别"而无法区分未建连与流式收尾失败。
    private var streamStartError: String?
    private var levelEnvelope: Float = 0
    /// 波形展示专用的响度包络,比 `levelEnvelope` 攻释更快,不参与判停,见 `ingestAudioLevel`。
    private var visualLevel: Float = 0
    /// 键盘录音键波形高频同步通道的节流状态,见 `ingestAudioLevel`。
    private var lastLevelPublishAt = Date.distantPast
    private static let levelPublishInterval: TimeInterval = 0.1
    private var recordingStartedAt = Date()
    private var lastVoiceAt = Date()
    private var hasDetectedSpeech = false
    /// 本次录音所处宿主输入框的语义。起录时从桥快照读一次并锁定——键盘可能在整理过程中
    /// 被切到别的输入框,而这次口述该怎么整理,取决于它**开始时**站在哪。
    /// 非键盘口述(App 内独立录音、Action 语音输入)恒为 `.general`,行为与改造前一致。
    private var activeFieldKind: HostFieldKind = .general
    /// Action Button 开始时 Shall We Talk 键盘所在的宿主输入文档。
    /// 开始时锁定、结束时再验证；中途切换输入框则只保留剪贴板备份。
    private var actionKeyboardInsertionTarget: KeyboardInsertionTarget?

    /// Silero VAD。模型不可用时 `isAvailable` 为 false,语音判定自动退回 RMS 阈值。
    private let voiceActivity = VoiceActivityDriver()
    /// VAD 报告的当前语音状态。仅在 `voiceActivity.isAvailable` 时有意义。
    private var vadSaysSpeaking = false
    private var bridgeTimer: Timer?
    /// iCloud 占位文件可能让同步文件 API 长时间等待；同步期间绝不能占用 MainActor。
    private var isCloudSyncing = false
    /// 词典/纠错同步的防抖任务(触发点:启动/回前台、词典编辑保存后、挖掘出新纠错对后)。
    private var dictionarySyncDebounceTask: Task<Void, Never>?
    private var lastHandledKeyboardRequestID: String?
    private var keyboardBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// 捕捉路径专用,与键盘那份互不覆盖(见 beginCaptureBackgroundWindow 的说明)。
    private var captureBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isStarting = false
    private var interruptedWhileRecording = false
    /// 中断开始的时刻;`.ended` 到达时若已过太久(系统偶尔延迟送达,实测过 12 秒),
    /// 说明键盘/桥早已放弃这轮录音,不能再盲目续录——否则会凭空唤醒麦克风,
    /// 且大概率立刻撞上仍在收尾的会话再次被打断,形成自我震荡的唤醒循环(2026-08-19 真机诊断)。
    private var interruptionBeganAt: Date?
    private static let staleInterruptionResumeWindow: TimeInterval = 1.5
    /// SCK 待命期的预热 Recorder 曾被系统音频中断拆掉；中断结束后
    /// 必须主动补回，否则界面仍显示待命，键盘快照却已不再具备后台开录条件。
    private var interruptedScreenCaptureHotStandby = false
    /// 键盘发起的上一次起录时刻,用于去重连点 record / 抑制过早 stop(防亚秒录音塌缩)
    private var lastKeyboardStartAt = Date.distantPast
    /// 当前 .error 是否是"App 判断此刻无法在后台发起新录音"(而非偶发错误)。
    /// 只在 start() 开头重置,随 bridgePhase 是否仍为 .error 一起派生,不受 0.5s 心跳覆盖影响。
    private var lastErrorNeedsForeground = false
    /// 本次前台化是否来自键盘冷启动的 `voicepen://record`。只有这种情况才允许在
    /// PiP 建立后自动退回宿主 App——用户自己点图标打开 App、或操作按钮的 .capture
    /// 路径都不该被送走。
    private var coldKeyboardLaunch = false
    private var coldReturnRequest: (id: String, target: HostReturnTarget, at: TimeInterval)?
    /// 本次冷启动收到 `voicepen://record` 的时刻。所有冷路径耗时诊断都以它为锚点:
    /// 竞品实测是点击后约 287ms 就退回宿主,我们要能一眼看出时间花在哪一段。
    private var coldLaunchStartedAt: Date?
    /// 热会话最近一次键盘录音活动时间;超过 hotSessionIdleTimeout 未用即拆到冷状态。
    private var hotSessionLastActiveAt = Date()
    /// 热会话空闲超时:10 分钟。窗口内橙色麦克风指示灯常亮、其它 App 音频被 duck,
    /// 属设计接受的取舍(Typeless 同款);超时拆机后键盘自动回落跳转 Link 冷路径。
    private static let hotSessionIdleTimeout: TimeInterval = 600
    /// 操作按钮录音结束后保留 90 秒音频暖会话;此窗口内再按一次只需打开取样闸门。
    /// 窗口足够短，避免长时间显示麦克风指示/压低其它 App 音频。
    private static let captureHotSessionIdleTimeout: TimeInterval = 90

    /// 操作按钮捕捉专用的 VAD 静音阈值,**不走设置里那个 1.5/2.5/4 秒**(2026-08-07 用户要求)。
    ///
    /// 起因:操作按钮这条路的心智模型是「按一次开始、再按一次结束」,而 4 秒的 VAD 常常
    /// 抢在用户按第二次之前就把录音停了——用户那一按于是被判成「开始新一段」(见 §11.1e)。
    /// 键盘那条路相反,说完就想走,短阈值才好用,所以只单独放宽捕捉路径。
    ///
    /// ⚠️ 实际最坏等待是 **25 秒**不是 10 秒:`DictationPolicy.shouldAutoStop` 对「话没说完」
    /// (整理稿不在句末)会把预算放宽到 2.5 倍,只有句末停顿才在 10 秒整停。
    private static let captureVADSilenceSeconds: TimeInterval = 10

    /// 「录音中」卡片的文案。起录与 0.5 秒心跳必须用**同一个**字符串,否则两边构造的
    /// ContentState 永不相等,心跳每一拍都会判定需要更新并推送一次。
    private static let captureRecordingMessage = "正在录音并转写，再按一次操作按钮结束"

    private static let log = OSLog(subsystem: "org.example.voicepen", category: "DictationController")

    /// 将共享 ASR 会话的无敏感快照落到 iOS 本机历史。字段和 Mac 保持同口径，
    /// 以便直接比较两端的建连、上行、首回包与终稿时间线。
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

    // 免费账号(无 App Group)用 Darwin 通知做键盘⇄App 信令
    private let darwin = DarwinObserver()
    private var lastDarwinPhase: KeyboardBridgePhase?

    /// 纯视图层修复(2026-07-13 真机反馈):todos 是嵌套 ObservableObject,其变更不会自动
    /// 触发本对象的 objectWillChange——只观察 controller 的视图(TodosTab / tab badge)在
    /// 滑动完成/删除后拿不到刷新,要等 phase 等自身 @Published 变化才"顺带"更新。
    /// 这里把 TodoStore 的变更转发出去;不涉及任何录音/桥/状态机逻辑。
    private var todosChangeForwarder: AnyCancellable?
    /// 同一类修复(2026-08-19):`settings`(MobileSettingsStore)也是嵌套 ObservableObject,
    /// 词典/纠错对页里 `settings.objectWillChange.send()`(如 `deleteCorrection`)不会自动
    /// 触发本对象的 objectWillChange——按删除键后台数据确实改了,但只观察 controller 的
    /// 词典设置页拿不到刷新信号,界面看起来"按了没反应",要等下一次 phase 等自身
    /// @Published 变化"顺带"更新才会显示出来。转发方式与 todosChangeForwarder 一致。
    private var settingsChangeForwarder: AnyCancellable?

    init() {
        todosChangeForwarder = todos.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        settingsChangeForwarder = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        startKeyboardBridge()
        startDarwinBridge()
        startAudioInterruptionObserver()
        startColdPathLifecycleObserver()
        // 纯音频待命的存活判据必须来自真实引擎状态,不能由机制自己说了算
        // (§13.2「进程存在≠后台可用」、§11.1「start() 没抛错≠在录音」)。
        // 注入而不是让机制持有 Recorder:Recorder 是 DictationController 的私有实现细节,
        // 待命机制只需要一个布尔答案。
        AudioSessionStandbyController.shared.isRecorderEngineLive = { [weak self] in
            self?.recorder.isEngineLive ?? false
        }
        StandbyController.shared.onStopped = { [weak self] in
            guard let self, self.standbyEnabled else { return }
            self.deactivateStandby(
                status: "\(StandbyController.mechanismDisplayName)已关闭",
                teardownWhenIdle: !StandbyController.keepsRecorderHot
            )
        }
        // 端侧语音模型资产预下载:离线兜底要在没网时能用,模型必须提前趁有网时装好。
        // fire-and-forget,失败只意味着端侧这次不可用,不影响云端主链路。
        if #available(iOS 26.0, *) {
            Task.detached(priority: .utility) { await OnDeviceTranscriber.prepareAssets() }
        }
        DiagLog.recordSelfCheck()       // 落盘自检,结果写进 App Group 的 diagLogSelfCheck
        DiagLog.mirrorToAppContainer()  // 镜像到 App 容器,绕开 devicectl 拉不到 App Group 子目录
        publishDictionaryToKeyboard()   // 启动即把词典镜像给键盘,首用即同源
        // 新进程刚起来,不可能有正在进行的录音。上一次 Action 捕捉若随进程一起死掉(后台被系统
        // 回收),App Group 里的"正在录音"标记就没人清,此后每一次操作按钮都会被解释成"停止"——
        // 按钮直到标记过期为止彻底失效,且那条分支不写日志,现场毫无线索(2026-08-06 实测)。
        if ActionCaptureSessionStore.isRecording {
            DiagLog.log("actionCapture", "启动时清除上一次会话遗留的录音标记")
            ActionCaptureSessionStore.clear()
        }
        // 操作按钮可能在视图出现前就已写入请求;这里尽早消费,缩短按键→开麦。
        Task { [weak self] in self?.consumeActionCaptureRequest() }
        // 启动后延迟拉取 iCloud 历史
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.syncHistoryFromCloud()
        }
        scheduleDictionarySync(reason: "启动")
        syncCredentials(reason: "启动")
    }

    /// 凭证跨设备同步。**不做防抖**:重装后第一次启动就要尽快把凭证拉回来,晚一秒就
    /// 多一秒"没配置"的错觉;而它一轮只有一次小文件读写,不值得攒。
    /// I/O 全在后台线程,只有应用回本机这一步回 MainActor(§11 的 watchdog 硬规矩)。
    func syncCredentials(reason: String) {
        guard settings.iCloudSyncEnabled else { return }
        Task { [weak self] in
            if let remote = await Task.detached(priority: .utility, operation: {
                CredentialSyncCoordinator.loadRemote()
            }).value, let self {
                CredentialSyncCoordinator.apply(remote, to: self.settings)
            }
            guard let self,
                  let snapshot = CredentialSyncCoordinator.localSnapshot(of: self.settings)
            else { return }
            let pushed = await Task.detached(priority: .utility, operation: {
                CredentialSyncCoordinator.pushIfChanged(snapshot)
            }).value
            if let pushed { CredentialSyncCoordinator.markPushed(at: pushed) }
            _ = reason
        }
    }

    /// 删除一条纠错对(词典页统一入口,不分手动/自动学习/云端同步来源)。
    func deleteCorrection(source: String) {
        settings.deleteCorrection(source: source)
        scheduleDictionarySync(reason: "纠错对删除")
    }

    /// 防抖(5s)触发一轮词典 + 纠错对跨设备同步;失败静默重试,不打扰用户。
    /// 触发点:启动、回前台、词典编辑保存后、挖掘出新纠错对后。
    func scheduleDictionarySync(reason: String) {
        guard settings.dictionarySyncEnabled else {
            lastDictionarySyncStatus = "词典同步未开启"
            return
        }
        DiagLog.log("dictSync", "计划同步 reason=\(reason)")
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

    /// 立即触发一轮同步,跳过 5s 防抖——供词典设置页的"立即同步"按钮使用:用户刚删了
    /// 一批词、想马上把这次删除(墓碑)推上云端时,不想等自动防抖窗口。
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
        publishDictionaryToKeyboard()
        scheduleDictionarySync(reason: "词典备份导入")
        return "已导入 \(preview.added) 项，保留本机冲突项 \(preview.conflicts) 项"
    }

    func syncDictionaryNow() {
        guard settings.dictionarySyncEnabled else {
            lastDictionarySyncStatus = "词典同步未开启"
            return
        }
        DiagLog.log("dictSync", "计划同步 reason=手动")
        dictionarySyncDebounceTask?.cancel()
        dictionaryRetryTask?.cancel()
        dictionaryRetryAttempt = 0
        Task { await runDictionarySync() }
    }

    /// 实际执行一轮同步:纯值快照进 Task.detached(iCloud 文件 I/O 可能等待,绝不能占用
    /// MainActor),合并结果回 MainActor 应用回 Settings + 镜像给键盘。
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
        let corrections = DictionaryMiner.correctionPairs(records: history.records, blocked: blockedCorrections)
            + settings.manualCorrections
        let result = await Task.detached(priority: .utility) {
            DictionarySyncCoordinator.syncAndMerge(
                currentManual: manual, currentAuto: auto, currentBlocked: blocked,
                corrections: corrections, currentBlockedCorrections: blockedCorrections)
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
            DiagLog.log("dictSync", "同步失败: \(String(describing: result))")
            return
        }
        guard settings.dictionarySyncEnabled else { return }
        if manual != settings.manualDictionaryWords || auto != settings.autoDictionaryWords
            || blocked != settings.blockedDictionaryWords { dictionarySyncRequested = true }
        DictionarySyncCoordinator.apply(merged, to: settings, startingManual: manual, startingAuto: auto)
        publishDictionaryToKeyboard() // 合并结果可能改了生效词表,重新镜像给键盘
        dictionaryRetryAttempt = 0
        lastDictionarySyncDate = Date()
        UserDefaults.standard.set(lastDictionarySyncDate, forKey: "dictionary.lastSuccessfulSync")
        lastDictionarySyncStatus = "已同步 · 词典 \(settings.dictionaryWords.count) · 纠错 \(merged.corrections.count)"
        DiagLog.log("dictSync", "已应用合并结果: \(lastDictionarySyncStatus)")
    }

    func syncHistoryFromCloud() {
        guard settings.iCloudSyncEnabled else {
            lastCloudSyncStatus = "iCloud 同步未开启"
            return
        }
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        lastCloudSyncStatus = "正在检查 iCloud…"
        let localRecords = history.records
        let localDeletions = history.deletionTombstones
        Task { [weak self] in
            // CloudHistorySync 使用同步文件 API；显式移出 MainActor，避免冻结录音停止键和全部 UI。
            let result = await Task.detached(priority: .utility) {
                guard CloudHistorySync.isAvailable else {
                    return (available: false, pull: Optional<CloudHistorySync.PullResult>.none)
                }
                guard let pull = CloudHistorySync.pull(
                    into: localRecords, localDeletions: localDeletions) else {
                    return (available: true, pull: Optional<CloudHistorySync.PullResult>.none)
                }
                return (available: true, pull: Optional(pull))
            }.value
            guard let self else { return }
            guard result.available else {
                self.isCloudSyncing = false
                self.lastCloudSyncStatus = "iCloud 不可用"
                return
            }
            if let pull = result.pull {
                let merged = self.history.applyCloudMerge(cloudRecords: pull.cloudRecords)
                let latestRecords = self.history.records
                let latestDeletions = self.history.deletionTombstones
                let push = await Task.detached(priority: .utility) {
                    CloudHistorySync.pushAll(latestRecords, deletions: latestDeletions)
                }.value
                var parts: [String] = []
                if merged.deferred { parts.append("本机历史暂时无法读取,本轮云端内容已缓存,恢复后自动合并") }
                if merged.inserted > 0 { parts.append("新增 \(merged.inserted) 条") }
                if merged.removed > 0 { parts.append("删除 \(merged.removed) 条") }
                if merged.adoptedFinal > 0 { parts.append("更新最终稿 \(merged.adoptedFinal) 条") }
                if push.failed > 0 { parts.append("写入失败 \(push.failed) 条") }
                self.lastCloudSyncStatus = parts.isEmpty
                    ? "已检查 iCloud,暂无新内容"
                    : "已从 iCloud " + parts.joined(separator: " · ")
            } else {
                self.lastCloudSyncStatus = "iCloud 读取失败"
            }
            self.isCloudSyncing = false
        }
    }

    func syncHistoryToCloud() {
        guard settings.iCloudSyncEnabled else {
            lastCloudSyncStatus = "iCloud 同步未开启"
            return
        }
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        lastCloudSyncStatus = "正在上传到 iCloud…"
        let records = history.records
        let deletions = history.deletionTombstones
        Task { [weak self] in
            let push = await Task.detached(priority: .utility) { () -> CloudHistorySync.PushResult? in
                guard CloudHistorySync.isAvailable else { return nil }
                return CloudHistorySync.pushAll(records, deletions: deletions)
            }.value
            guard let self else { return }
            self.isCloudSyncing = false
            if let push, push.succeeded {
                self.lastCloudSyncStatus = "已上传 \(records.count) 条历史到 iCloud"
            } else if let push {
                self.lastCloudSyncStatus = "iCloud 写入失败 \(push.failed) 条"
            } else {
                self.lastCloudSyncStatus = "iCloud 不可用"
            }
        }
    }

    /// 删除历史并在 iOS 四秒撤销窗口结束后传播墓碑。
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

    func toggle() {
        switch phase {
        case .recording: Task { await finish() }
        case .processing: break
        default: Task { await start(source: .standalone) }
        }
    }

    /// 用户从主 App 明确开启/结束「免切换待命」。开启必须发生在前台，确保麦克风
    /// 权限与 AVAudioSession 激活均符合系统要求；随后键盘只恢复既有会话的采样闸门。
    /// 用户亲手拨开关。**只有这里会改偏好**——到期、来电中断、进程回收走的都是
    /// `deactivateStandby`,那些只落运行时状态,偏好原样保留,下次回前台照样补建。
    func setStandbyEnabled(_ enabled: Bool) {
        settings.standbyPreferredOn = enabled
        if enabled {
            // 会议录音独占 AVAudioSession。保留用户刚刚选择的偏好，但不能在会议中
            // 重新拉起 PiP/待命；会议结束后 reclaimAudioAfterMeeting 会按该偏好恢复。
            guard !MeetingRecordingController.shared.isActive else {
                standbyArmRetryTask?.cancel()
                standbyArmRetryTask = nil
                standbyStatus = "会议录音中，待命将在结束后恢复"
                publishKeyboardBridgeState()
                Self.recordTrace("会议录音中仅保存待命偏好，不启动待命")
                return
            }
            StandbyController.shared.requestStartFromUserAction()
            Task { await activateStandby() }
        } else {
            standbyArmRetryTask?.cancel()
            standbyArmRetryTask = nil
            deactivateStandby(status: "已由你关闭")
        }
    }

    /// 偏好为开就补建待命。PiP 可以自动补建；SCK 每个新进程都必须由
    /// 用户动作弹出系统分享面板，因此普通启动只更新提示，不自动弹窗。
    /// 挂在场景变 `.active` 上——`tryArmStandby` 要求 `applicationState == .active`,
    /// 更早的时机必被 AVKit 以 -1001 拒绝(见该函数里 build 70 那段实测记录)。
    func armStandbyIfPreferred() {
        guard settings.standbyPreferredOn else { return }
        guard !MeetingRecordingController.shared.isActive else {
            Self.recordTrace("会议录音中，跳过按偏好恢复待命")
            return
        }
        if standbyEnabled, recorder.isHot { return }
        guard !standbyEnabled, !standbyIsStarting, standbyArmRetryTask == nil else { return }
        guard phase != .recording, phase != .processing else { return }
        if StandbyController.requiresSystemAuthorization {
            standbyStatus = "点击“一键开始授权与待命”"
            publishKeyboardBridgeState()
            return
        }
        startStandbyArmAttempts(reason: "偏好为开")
    }

    /// 会议录音要独占 AVAudioSession:先拆掉待命/热会话,避免两个 `Recorder` 实例
    /// 争抢同一个音频会话(见 `MeetingRecordingController.start()`)。`phase` 此时
    /// 必为 `.idle`(调用方已经守了 `!MeetingRecordingController.shared.isActive` 才会走到会议起录,
    /// 而会议起录本身又是 `DictationController` 不在录音/整理时才允许发生的)。
    func yieldAudioForMeeting() {
        // 取消尚未执行的重试，并拆除半启动态的 PiP。否则一个已排队的前台回调可能
        // 在会议开始后重新配置 AVAudioSession，造成会议 PCM 短暂断流。
        standbyArmRetryTask?.cancel()
        standbyArmRetryTask = nil
        if standbyEnabled {
            deactivateStandby(status: "让位给会议录音", teardownWhenIdle: true)
        } else {
            StandbyController.stopAll()
        }
        recorder.teardown()
        publishKeyboardBridgeState()
    }

    /// 会议结束后按用户偏好把待命补回来,与前台化时的既有幂等入口(`armStandbyIfPreferred`)
    /// 是同一个函数——两处都只是"该不该有待命"的复查,重复调用无害。
    func reclaimAudioAfterMeeting() {
        armStandbyIfPreferred()
    }

    func restartStandbyWithSelectedDuration() {
        guard !MeetingRecordingController.shared.isActive else {
            standbyStatus = "会议录音中，待命将在结束后恢复"
            publishKeyboardBridgeState()
            return
        }
        guard standbyEnabled else { return }
        deactivateStandby(status: "正在更新时长", teardownWhenIdle: false)
        StandbyController.shared.requestStartFromUserAction()
        Task { await activateStandby() }
    }

    /// 设置页切换后台机制时立即拆掉旧实现。不能等用户再关一次开关：此时偏好已经变了，
    /// `StandbyController.shared` 会指向新实现，旧的 ScreenCapture 流会被漏掉。
    func standbyMechanismPreferenceDidChange() {
        standbyArmRetryTask?.cancel()
        standbyArmRetryTask = nil
        standbyRebuildAttempts = 0
        standbyEnabled = false
        standbyEndsAt = nil
        standbyStatus = "待命机制已切换，请重新开启待命"
        StandbyLiveActivityController.shared.end()
        StandbyController.stopAll()
        if phase != .recording, phase != .processing {
            recorder.teardown()
        }
        publishKeyboardBridgeState()
        Self.recordTrace("待命机制偏好已切换；旧实现已全部停止")
    }

    /// - Parameter duringRecording: 正在录音时顺带把待命建起来(键盘冷启动首次口述用)。
    ///   此时**不能**拆录音引擎——`recorder.teardown()` 会当场掐断这次口述——
    ///   而待命机制本身与录音可以共存。
    /// - Parameter allowInactiveForeground: 键盘冷启动经 voicepen://record 拉起时,App 停在
    ///   `.inactive` 这个过渡态前台,永远不会变成 `.active`。自动路径必须放宽到"只排除真正的
    ///   `.background`";手动从设置开关开启时仍要求 `.active`。
    ///   **不能复用 `duringRecording` 判断这件事**——2026-08-04 实测:arm 发生在 phase 尚未变成
    ///   `.recording` 的瞬间时 `duringRecording=false`,守卫退回 `.active`,自动开启永远失败。
    private func activateStandby(duringRecording: Bool = false,
                                 allowInactiveForeground: Bool = false) async {
        guard !MeetingRecordingController.shared.isActive else {
            Self.recordTrace("会议录音中，拒绝启动待命")
            return
        }
        guard !standbyIsStarting else { return }
        if !duringRecording {
            guard phase != .recording, phase != .processing else {
                standbyStatus = "请在本次录音完成后开启"
                return
            }
        }
        standbyIsStarting = true
        defer { standbyIsStarting = false }

        // 手动从设置开关开启时要求 .active;自动路径(duringRecording)发生在键盘冷启动的
        // .inactive 过渡态前台里,只排除真正的 .background。
        let appState = UIApplication.shared.applicationState
        let stateOK = allowInactiveForeground ? appState != .background : appState == .active
        guard stateOK else {
            standbyStatus = "请回到 Shall We Talk 后开启"
            Self.recordTrace("activateStandby 中止:state=\(appState.rawValue) allowInactive=\(allowInactiveForeground)")
            // 此处已经调过 requestStartFromUserAction(它内部就调了 startPictureInPicture),
            // 中止而不收尾会把控制器留在"已请求未激活"的半启动态(实测 requested=true PiP=false)。
            StandbyController.stopAll()
            return
        }
        guard await ensureMicrophoneAccess() else {
            standbyStatus = "请先允许麦克风权限"
            return
        }
        // `ensureMicrophoneAccess` 会跨 await；期间可能已从键盘路径切换到会议录音。
        guard !MeetingRecordingController.shared.isActive else {
            Self.recordTrace("会议录音开始后，取消待命启动")
            return
        }

        do {
            let duration = settings.standbyDuration
            if !duringRecording {
                if StandbyController.keepsRecorderHot {
                    // SCK 负责后台调度、纯音频待命的后台资格就是这条会话本身;
                    // 两者都由 Recorder 负责真正取样。必须在用户仍在前台时建好热引擎,
                    // 退到键盘后再新建会被 iOS 以 `!rec` 拒绝(§11.1)。
                    recorder.teardown()
                    try recorder.warmUp()
                } else {
                    recorder.teardown()
                }
            }
            try await StandbyController.shared.start()
            // `start()` 也会跨 await。若会议恰好在这段时间开始，起录路径虽已调用
            // stopAll，迟到返回的这里仍不能把待命状态重新标成已启用。
            guard !MeetingRecordingController.shared.isActive else {
                StandbyController.stopAll()
                standbyEnabled = false
                standbyEndsAt = nil
                Self.recordTrace("会议录音开始后，回收迟到完成的待命启动")
                return
            }
            standbyEndsAt = duration.interval.map { Date().addingTimeInterval($0) }
            standbyEnabled = true
            let durationLabel = duration == .untilInterrupted ? "直到被中断" : duration.rawValue
            standbyStatus = StandbyController.standbyRunningStatus(durationLabel: durationLabel)
            hotSessionLastActiveAt = Date()
            publishKeyboardBridgeState()
            standbyRebuildAttempts = 0
            Self.recordTrace("待命已开启 duringRecording=\(duringRecording) duration=\(duration.rawValue)")
            // PiP 确认 active 的唯一时刻——冷启动自动返回宿主的两个必要条件之一。
            maybeStartColdReturn(trigger: "PiP active")
        } catch {
            // 录音进行中失败时绝不能 teardown——那会连带掐掉用户正在说的这一段。
            if !duringRecording { recorder.teardown() }
            standbyEnabled = false
            standbyEndsAt = nil
            standbyStatus = "开启失败：\(Self.friendlyStartError(error as NSError, fallback: error.localizedDescription))"
            publishKeyboardBridgeState()
            Self.recordTrace("待命开启失败 duringRecording=\(duringRecording) err=\(Self.diagnosticDescription(error as NSError))")
        }
    }

    private var standbyActivityMessage: String {
        if settings.standbyDuration == .untilInterrupted {
            return "键盘可直接开录；来电、Siri 或系统中断后自动结束"
        }
        return "键盘可直接开录；空闲时不保存、不上传声音"
    }

    /// 音频中断(来电 / Siri / 其他 App 抢音频)时是否该连带关掉待命。
    ///
    /// 画中画时代:是 —— PiP 与音频会话有真实耦合,中断后 PiP 也多半活不下去。
    /// ScreenCaptureKit 时代:**否** —— 屏幕捕获会话与音频中断毫无关系,
    /// 关掉它纯属误伤。2026-08-12 真机实测就是这条误伤把待命打没的:
    /// 待命只活了 4.4 秒,一次音频中断就被连带关闭,而后 filter 失效再也起不来。
    /// 2026-09-08 补:纯音频待命同样**否** —— 它的会话被中断打断后应该走恢复分支
    /// (`resumeHotStandbyAfterInterruption`),由系统的 `shouldResume` 决定去留;
    /// 直接关掉待命会让用户在一次来电后莫名其妙失去待命。
    private var audioInterruptionShouldEndStandby: Bool {
        !StandbyController.keepsRecorderHot
    }

    private func deactivateStandby(status: String, teardownWhenIdle: Bool = true) {
        let wasEnabled = standbyEnabled
        let wasScreenCapture = StandbyController.keepsRecorderHot
        if wasEnabled { Self.recordTrace("待命关闭 status=\(status) phase=\(phase) mode=\(mode)") }
        standbyArmRetryTask?.cancel()
        standbyArmRetryTask = nil
        standbyRebuildAttempts = 0
        standbyEnabled = false
        standbyEndsAt = nil
        standbyStatus = status
        StandbyLiveActivityController.shared.end()
        StandbyController.stopAll()
        if teardownWhenIdle, phase != .recording, phase != .processing {
            recorder.teardown()
        } else if wasScreenCapture, phase != .recording, phase != .processing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        publishKeyboardBridgeState()
        if wasEnabled { DiagLog.log("standby", "已结束: \(status)") }
    }

    func startIfIdle() {
        if !isStarting && phase != .recording && phase != .processing {
            if mode == .keyboard {
                let snapshot = KeyboardBridgeStore.snapshot()
                if let baseText = snapshot.editBaseText, !baseText.isEmpty,
                   snapshot.requestID.hasPrefix("edit:") {
                    editingTarget = EditTarget(recordID: nil, baseText: baseText)
                }
            }
            beginKeyboardBackgroundWindow()
            // 只有键盘冷启动这一趟才有"把用户送回宿主"的义务(见 ColdReturnCoordinator)。
            coldKeyboardLaunch = (mode == .keyboard)
            if coldKeyboardLaunch {
                coldLaunchStartedAt = Date()
                ColdReturnCoordinator.resetForNewForegroundSession()
                let snapshot = KeyboardBridgeStore.snapshot()
                coldReturnRequest = snapshot.returnTarget.map { (snapshot.requestID, $0, snapshot.requestSentAt) }
            }
            // 2026-08-04 实测教训:不要在这里抢先 arm 画中画。openURL 这一刻 App 还停在
            // `.inactive`,AVKit 直接以 -1001 拒绝 startPictureInPicture,而这次失败会让
            // 后续重试拖到 4–6 秒才 active(build 68 首版实测)。arm 仍然只挂在起录成功
            // 之后 + `didBecomeActive` 事件上(见 autoEnableKeyboardStandbyIfNeeded)。
            // 这是冷路径的唯一合法起录来源(source=.openURL),豁免 start() 的冷路径守卫、允许在 .inactive 前台化中起录。
            Task { await start(source: .openURL) }
        }
    }

    private func startKeyboardBridge() {
        bridgeTimer?.invalidate()
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickKeyboardBridge() }
        }
        if let bridgeTimer {
            RunLoop.main.add(bridgeTimer, forMode: .common)
        }
        publishKeyboardBridgeState()
    }

    // MARK: - Darwin 信令(免费账号)

    private func startDarwinBridge() {
        darwin.observe(DarwinBridge.cmdStart) { [weak self] in self?.handleDarwinStart() }
        darwin.observe(DarwinBridge.cmdStop) { [weak self] in self?.handleDarwinStop() }
        // 付费(App Group)模式:键盘写完桥请求会发 cmdKick,收到即刻处理,免等 0.5s 轮询
        darwin.observe(DarwinBridge.cmdKick) { [weak self] in self?.tickKeyboardBridge() }
        darwin.observe(DarwinBridge.cmdCapture) { [weak self] in self?.consumeActionCaptureRequest() }
        darwin.observe(DarwinBridge.cmdCaptureStop) { [weak self] in self?.consumeActionCaptureStopRequest() }
    }

    /// 消费操作按钮请求。录音中再按一次作为停止;其余状态从通用语音输入模式起录。
    func consumeActionCaptureRequest() {
        Task { await consumeActionCaptureRequestAndWait() }
    }

    /// 给 AudioRecordingIntent 使用的等待式入口。意图会保持执行到麦克风真正出声(不只是引擎没抛错)；
    /// 第二次按键则保持到识别、剪贴板/记录交付和 Live Activity 完成态均已提交，避免后台提前挂起。
    ///
    /// 返回值 = 本次按键是否真的把录音跑起来了。false 表示后台开麦被系统拒绝，
    /// 由 `StartTodoCaptureIntent` 决定是否切到前台重来一次。
    /// - Parameter canRetryInForeground: 调用方(意图)在本次失败后还会不会切前台重来。
    ///   为 true 时零样本中止走静默收尾,不弹「录音未完成」——那条提示紧接着就会被一次成功
    ///   的重试推翻,先报错再成功比不报错更让人困惑。
    @discardableResult
    func consumeActionCaptureRequestAndWait(canRetryInForeground: Bool = false) async -> Bool {
        guard let requested = ActionCaptureRequestStore.consume() else {
            // 同一次按键的另一条通道(Darwin cmdCapture)已经抢先接单:不能就此返回,
            // 否则 AppIntent 的执行窗口会在麦克风还没跑起来时就关闭。等它的结果。
            guard isStarting || (phase == .recording && mode == .capture) else { return false }
            return await confirmCaptureIsReceivingAudio(canRetryInForeground: canRetryInForeground)
        }
        let dispatchMs = Date().timeIntervalSince(requested.date) * 1000
        DiagLog.log("perf", "Action Button→App接单=\(String(format: "%.0f", dispatchMs))ms phase=\(phase)")
        if phase == .recording, mode == .capture {
            await finish()
            return true
        }
        guard phase != .recording, phase != .processing, !isStarting else { return false }
        pendingClipboardCopy.clear()
        shortcutClipboardMessage = nil
        actionKeyboardInsertionTarget = KeyboardBridgeStore.activeKeyboardInsertionTarget()
        if let target = actionKeyboardInsertionTarget {
            DiagLog.log("actionCapture", "已锁定 Shall We Talk 输入文档=\(target.documentID.uuidString)")
        } else {
            DiagLog.log("actionCapture", "开始时无活跃 Shall We Talk 键盘，将仅使用剪贴板交付")
        }
        mode = .capture
        actionForceTodo = requested.forceTodo
        // 待命开着时也必须建捕捉卡片。两张卡 source 不同("standby" / "actionButton"),互不覆盖;
        // 而 AudioRecordingIntent 能在后台开麦,前提就是全程有一张可见的 Live Activity——
        // 2026-08-06 实测:待命开着时跳过 begin(),后台起录不报错但一个音频缓冲都收不到。
        await CaptureLiveActivityController.shared.begin()
        await start(source: .openURL)
        let started = await confirmCaptureIsReceivingAudio(canRetryInForeground: canRetryInForeground)
        if started {
            // 只在**确认收到音频之后**才提示。沿用本项目一贯的判据:
            // "start() 没抛错"不等于"在录音"(§11.1 / §12.20)。
            CaptureLiveActivityController.shared.announceRecording(message: "Shall We Talk 正在听")
            // 起录:震一下。只在 App 不在前台时提示 —— 在前台时用户看得见界面。
            if UIApplication.shared.applicationState != .active {
                BackgroundCue.buzz(times: 1)
            }
        }
        return started
    }

    /// 确认麦克风真的在出声。`recorder.start()` 不抛错只说明引擎起来了;后台开麦被 iOS 静默
    /// 拒绝时 tap 永远不回调,`phase` 却停在 `.recording`——录音成了黑洞,进程随后被回收,
    /// 而 `ActionCaptureSessionStore` 里的"正在录音"标记再也没人清(2026-08-06 真机日志)。
    private func confirmCaptureIsReceivingAudio(timeout: TimeInterval = 1.5,
                                                canRetryInForeground: Bool = false) async -> Bool {
        guard mode == .capture else { return phase == .recording }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.capturedByteCount > 0 { return true }
            // 起录本身就失败了(start 的 catch 已把 phase 打成 .error 并收好尾),不必再判样本。
            if !isStarting, phase != .recording { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let finalBytes = recorder.capturedByteCount
        guard finalBytes == 0 else { return true }
        abortCaptureWithoutAudio(retrying: canRetryInForeground)
        return false
    }

    /// 后台开麦被拒时的收尾:拆掉空转的音频会话、清跨进程标记、让灵动岛给出可见失败。
    /// 不留 `.error`,好让紧接着的前台重试不被 start() 的状态守卫挡住。
    private func abortCaptureWithoutAudio(retrying: Bool = false) {
        DiagLog.log("start", "后台开麦被系统拒绝(引擎已启动但零样本),中止本次 Action 捕捉 将重试=\(retrying)")
        _ = recorder.stop()
        recorder.teardown()
        recorder.onChunk = nil
        recorder.onLevel = nil
        streamSession?.cancel(); streamSession = nil
        levelEnvelope = 0; audioLevel = 0; visualLevel = 0; lastLevelPublishAt = .distantPast
        phase = .idle
        ActionCaptureSessionStore.clear()
        if !retrying { actionKeyboardInsertionTarget = nil }
        if retrying {
            // 静默收尾:紧接着的前台重试会建一张新卡片,这里先报"未完成"只会闪一下错。
            CaptureLiveActivityController.shared.endSilently()
        } else {
            CaptureLiveActivityController.shared.fail(message: "后台无法开启麦克风")
        }
        publishKeyboardBridgeState()
    }

    /// 第二次 Action 按键的专用停止入口。请求在 App Group 落盘，Darwin 通知只是低延迟加速；
    /// 即使通知与 AppIntent 分处不同进程或偶发丢失，下一次 0.5 秒心跳仍会消费同一请求。
    private func consumeActionCaptureStopRequest() {
        guard phase == .recording, mode == .capture else {
            // 没有正在进行的捕捉:这条停止请求来自已经死掉的上一次会话。消费掉丢弃,
            // 否则它会一直躺在 App Group 里,等下一次真正起录时被心跳误当成"立刻停止"。
            if ActionCaptureSessionStore.consumeStopRequest() {
                DiagLog.log("actionCapture", "丢弃过期停止请求 phase=\(phase) mode=\(mode)")
            }
            return
        }
        guard ActionCaptureSessionStore.consumeStopRequest() else { return }
        Task { await finish() }
    }

    private func handleDarwinStart() {
        mode = .keyboard
        beginKeyboardBackgroundWindow()
        // 同一次点击的重复信令:冷启动时 Link 会同时 openURL 和发信令,openURL 那条已经在起录,
        // 这里必须先认出来直接返回。否则下面的冷路径守卫会把已经成功的 .recording 打成 .error,
        // 用户看到"无法录音",非得再点一次才行(2026-08-04 实测的双击问题根因)。
        if isStarting || phase == .recording || phase == .processing {
            Self.recordTrace("Darwin start 忽略:openURL 已在起录 isStarting=\(isStarting) phase=\(phase)")
            return
        }
        // 冷路径守卫:无热会话且 App 非前台活跃时,绝不由 Darwin 请求起录——否则抢在前台化前冷激活会话、
        // 毒化后续 openURL 起录。回发 needsForeground 让键盘露出跳转 Link,交 voicepen://record 前台唯一起录。
        if !canStartRecordingInBackground, UIApplication.shared.applicationState != .active {
            DiagLog.log("bridge", "Darwin start 冷路径:不由信令起录,发布 needsForeground(交 openURL 前台起录)")
            lastErrorNeedsForeground = true
            phase = .error("需要切换到 App 才能开始录音")
            publishKeyboardBridgeState()
            return
        }
        if phase != .recording && phase != .processing {
            Task { await start(source: .darwin) }
        }
    }

    private func handleDarwinStop() {
        if phase == .recording {
            Task { await finish() }
        }
    }

    // MARK: - 音频会话中断处理(来电/其它 App 抢占麦克风等)

    private func startAudioInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioInterruption(note) }
        }
        // 路由变化只记诊断日志(耳机/蓝牙插拔是热会话失效的常见诱因),不做任何行为
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            DiagLog.log("audio", "路由变化 reason=\(reason)")
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            DiagLog.log(
                "audio",
                "中断开始 phase=\(phase) isHot=\(recorder.isHot) hotIntent=\(recorder.hasHotSessionIntent)"
            )
            if phase == .recording {
                interruptedWhileRecording = true
                interruptionBeganAt = Date()
                stopForInterruption()
            } else if recorder.hasHotSessionIntent {
                // 通知到达前引擎已可能被系统停掉，不能用 isHot 判断中断前
                // 是否有热会话。build 135 真机就是 isHot=false / hotIntent=true。
                DiagLog.log("hot", "热会话空闲期被中断,拆到冷状态")
                interruptedScreenCaptureHotStandby = standbyEnabled && StandbyController.keepsRecorderHot
                recorder.teardown()
                if standbyEnabled {
                    {
                        if audioInterruptionShouldEndStandby {
                            deactivateStandby(status: "已被来电、Siri 或系统音频中断", teardownWhenIdle: false)
                        } else {
                            Self.recordTrace("音频中断,但屏幕捕获待命与音频无关,保持不动")
                        }
                    }()
                }
                publishKeyboardBridgeState()
            }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                .contains(.shouldResume)
            DiagLog.log(
                "audio",
                "中断结束 options=\(optionsValue) shouldResume=\(shouldResume) "
                    + "wasRecording=\(interruptedWhileRecording) "
                    + "resumeSCKHot=\(interruptedScreenCaptureHotStandby)"
            )
            if interruptedScreenCaptureHotStandby {
                interruptedScreenCaptureHotStandby = false
                guard shouldResume else {
                    deactivateStandby(status: "音频中断后系统不允许恢复麦克风", teardownWhenIdle: false)
                    return
                }
                guard standbyEnabled, StandbyController.keepsRecorderHot else {
                    return
                }
                Task { await resumeHotStandbyAfterInterruption() }
                return
            }
            guard interruptedWhileRecording else { return }
            interruptedWhileRecording = false
            let interruptionAge = interruptionBeganAt.map { Date().timeIntervalSince($0) }
            interruptionBeganAt = nil
            guard shouldResume else {
                if standbyEnabled, StandbyController.keepsRecorderHot {
                    deactivateStandby(status: "音频中断后系统不允许恢复麦克风", teardownWhenIdle: false)
                }
                return
            }
            guard (interruptionAge ?? 0) <= Self.staleInterruptionResumeWindow else {
                DiagLog.log(
                    "audio",
                    "中断结束但已过期(距开始\(String(format: "%.1f", interruptionAge ?? 0))s),放弃续录,回到 idle"
                )
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                DiagLog.log("audio", "中断后重新激活会话成功,续录")
                Task { await start(source: .resume) }
            } catch {
                DiagLog.log("audio", "中断后重新激活会话失败: \(Self.diagnosticDescription(error as NSError))")
                phase = .idle
                publishKeyboardBridgeState()
            }
        @unknown default: break
        }
    }

    /// 靠热引擎的两套待命(SCK / 纯音频)在音频中断后都需要有人重建 Recorder:
    /// SCK 的流自己活着但不管录音引擎;纯音频待命的会话本身就是被打断的那个。
    /// 只在系统明确给出 shouldResume 时补建,不做无限 retry。
    private func resumeHotStandbyAfterInterruption() async {
        do {
            try recorder.warmUp()
            hotSessionLastActiveAt = Date()
            standbyStatus = "\(StandbyController.mechanismDisplayName)待命中 · 录音引擎已从中断恢复"
            publishKeyboardBridgeState()
            DiagLog.log("hot", "\(StandbyController.mechanismName) 空闲热会话已在音频中断结束后恢复")
        } catch {
            DiagLog.log("hot", "\(StandbyController.mechanismName) 空闲热会话恢复失败: \(Self.diagnosticDescription(error as NSError))")
            deactivateStandby(status: "音频中断后无法恢复麦克风待命", teardownWhenIdle: false)
        }
    }

    /// 中断导致的清理:直接切断录音、丢弃本次流式会话,不走完整识别/整理流程。
    private func stopForInterruption() {
        _ = recorder.stop()
        recorder.onChunk = nil
        recorder.onLevel = nil
        streamSession?.cancel()
        streamSession = nil
        levelEnvelope = 0; audioLevel = 0; visualLevel = 0; lastLevelPublishAt = .distantPast
        phase = .idle
        if standbyEnabled {
            {
                        if audioInterruptionShouldEndStandby {
                            deactivateStandby(status: "已被来电、Siri 或系统音频中断", teardownWhenIdle: false)
                        } else {
                            Self.recordTrace("音频中断,但屏幕捕获待命与音频无关,保持不动")
                        }
                    }()
        }
        publishKeyboardBridgeState()
    }

    /// 免费账号:按 phase 变化广播 Darwin 事件 + 每次心跳。付费(App Group 可用)则跳过。
    private func emitDarwinState(_ phase: KeyboardBridgePhase) {
        guard !AppGroup.isAvailable else { return }
        DarwinBridge.post(DarwinBridge.evtAlive)   // 心跳:键盘据此判定 App 存活(可免跳转续录)
        if phase == .recording || phase == .processing {
            DarwinBridge.post(phase == .recording ? DarwinBridge.evtRecording : DarwinBridge.evtProcessing)
            lastDarwinPhase = phase
            return
        }
        if phase == .ready {
            DarwinBridge.post(DarwinBridge.evtResult)
            lastDarwinPhase = phase
            return
        }
        guard phase != lastDarwinPhase else { return }
        lastDarwinPhase = phase
        switch phase {
        case .recording: DarwinBridge.post(DarwinBridge.evtRecording)
        case .processing: DarwinBridge.post(DarwinBridge.evtProcessing)
        case .ready, .inserted: DarwinBridge.post(DarwinBridge.evtResult)   // 文本已入剪贴板
        case .error: DarwinBridge.post(DarwinBridge.evtError)
        default: break
        }
    }

    private func tickKeyboardBridge() {
        if phase == .recording, mode == .capture,
           ActionCaptureSessionStore.consumeStopRequest() {
            Task { await finish() }
            return
        }
        // 操作按钮录音全程保住灵动岛那张"正在录音"卡片。内部会先比对状态,
        // 没变就不推送,所以挂在 0.5 秒心跳上不会造成更新风暴。
        if phase == .recording, mode == .capture {
            CaptureLiveActivityController.shared.logCurrentActivityState(at: "录音心跳")
            CaptureLiveActivityController.shared.ensureRecording(
                startedAt: recordingStartedAt,
                message: Self.captureRecordingMessage
            )
        }
        // 显式待命优先于普通 10 分钟暖会话；到期、引擎被系统终止时立即退出并结束灵动岛。
        if standbyEnabled {
            if let standbyEndsAt, Date() >= standbyEndsAt {
                deactivateStandby(status: "待命时间已结束")
            } else if !StandbyController.shared.isActive,
                      !StandbyController.shared.isRecoveringUnexpectedSystemStop,
                      phase != .recording, phase != .processing {
                handleStandbyPictureInPictureLoss(reason: "心跳检查")
            } else if StandbyController.keepsRecorderHot,
                      !recorder.isHot,
                      !interruptedScreenCaptureHotStandby,
                      phase != .recording, phase != .processing {
                // SCK 流存活不代表录音引擎也存活。不再发布假的“可后台开录”快照；
                // 没有明确的 interruption-ended 恢复窗口时，只能诚实结束待命。
                deactivateStandby(status: "录音引擎已被系统中断，请重新开启", teardownWhenIdle: false)
            }
        }
        // 普通热会话空闲超时:拆到冷状态(App 随之失去音频保活被挂起,心跳过期,键盘回落跳转 Link)
        let hotTimeout = mode == .capture ? Self.captureHotSessionIdleTimeout : Self.hotSessionIdleTimeout
        if !standbyEnabled, recorder.isHot, phase != .recording, phase != .processing,
           Date().timeIntervalSince(hotSessionLastActiveAt) > hotTimeout {
            DiagLog.log("hot", "热会话空闲超时(\(Int(hotTimeout))s,mode=\(mode)),拆到冷状态")
            recorder.teardown()
        }
        publishKeyboardBridgeState()
        guard let request = KeyboardBridgeStore.pendingRequestAction(after: lastHandledKeyboardRequestID) else { return }
        // 根因修复:App 正在跑一个非键盘发起的口述(如待办页语音加提醒,mode=.capture/.standalone)时,
        // 绝不能被这条桥请求打断——尤其不能往下执行到 `mode = .keyboard`。此 tick 每 0.5s 跑一次
        // (且 cmdKick 会更即时地触发它),覆盖 mode 会让 finish() 里"mode==.capture 才入待办"的路由
        // 判断被悄悄改写成 .keyboard,导致语音加待办"识别完却什么都没加进列表"——这正是本轮要修的 bug。
        // 不 markRequestHandled/不推进 lastHandledKeyboardRequestID:请求原样留着,等当前非键盘会话结束
        // (phase 回到 idle/done/error)后,下一次 tick 自然再捡起来处理,不丢请求。
        let isForeignSession = (phase == .recording || phase == .processing) && .keyboard != mode
        if isForeignSession {
            DiagLog.log("bridge", "延后处理桥请求(App 正在跑非键盘会话 mode=\(mode) phase=\(phase)),避免覆盖 mode")
            return
        }
        lastHandledKeyboardRequestID = request.id
        // 起录延迟诊断:键盘点击(requestSentAt)→ App 接单 的毫秒数。cmdKick 生效后应≈个位数 ms;
        // 若无 kick、纯靠 0.5s 轮询,这里会是几百 ms——正是用户感知的那≈0.5s。
        let sentAt = KeyboardBridgeStore.snapshot().requestSentAt
        if sentAt > 0 {
            let waitMs = (Date().timeIntervalSince1970 - sentAt) * 1000
            DiagLog.log("perf", "桥请求延迟=\(String(format: "%.0f", waitMs))ms(点击→App接单)action=\(request.action.rawValue)")
        }
        KeyboardBridgeStore.markRequestHandled(request.id)
        DiagLog.log("bridge", "收到键盘请求 \(request.action.rawValue) id=\(request.id.suffix(8)) phase=\(phase) appState=\(UIApplication.shared.applicationState.rawValue) isHot=\(recorder.isHot)")
        mode = .keyboard
        beginKeyboardBackgroundWindow()
        switch request.action {
        case .record:
            // 冷路径守卫(核心修复):无热会话且 App 非前台活跃(.inactive/.background 都算)→ 绝不由桥请求起录。
            // cmdKick 让桥请求几乎即时送达,冷启动时它会抢在 voicepen://record 前台化之前跑 start(),
            // 在 .inactive 下冷激活会话→"没有可用输入设备",还毒化会话害得随后前台起录 '!int'。
            // 冷路径交给 openURL(startIfIdle)唯一起录;这里只回发 needsForeground 让键盘保持/露出跳转 Link。
            // 去重必须排在冷路径守卫**之前**:冷启动时 Link 会同时 openURL 和写桥请求,
            // openURL 那条是唯一合法起录并且已经跑起来了。若先跑冷路径守卫,它会把已经
            // 成功的 .recording 覆盖成 .error("需要切换到 App 才能开始录音"),用户看到"无法录音",
            // 必须再点一次才行——这正是 2026-08-04 实测到的"两次点击"根因。
            if isStarting || phase == .recording || phase == .processing
                || Date().timeIntervalSince(lastKeyboardStartAt) < 0.5 {
                Self.recordTrace("桥 record 忽略重复:isStarting=\(isStarting) phase=\(phase)")
                break
            }
            if !canStartRecordingInBackground, UIApplication.shared.applicationState != .active {
                Self.recordTrace("桥 record 冷路径:交 openURL 起录 state=\(UIApplication.shared.applicationState.rawValue)")
                lastErrorNeedsForeground = true
                phase = .error("需要切换到 App 才能开始录音")
                publishKeyboardBridgeState()
                break
            }
            if phase != .recording && phase != .processing {
                lastKeyboardStartAt = Date()
                Task { await start(source: .bridge) }
            }
        case .stop:
            // 防塌缩:距起录 <0.5s 就来的 stop(多半是排队的陈旧请求),忽略,避免亚秒录音"没有识别到内容"
            if phase == .recording, Date().timeIntervalSince(lastKeyboardStartAt) < 0.5 {
                DiagLog.log("bridge", "忽略过早 stop(距起录\(String(format: "%.2f", Date().timeIntervalSince(lastKeyboardStartAt)))s)")
                break
            }
            if phase == .recording {
                Task { await finish() }
            }
        case .edit:
            // 键盘修改模式(语音二次修改-执行方略.md v2 §6):守卫逻辑照抄 .record——
            // 键盘已经在宿主输入框里把要改的原文标成 marked text,这里只是多记一件事:
            // 接下来这段录音要走 EditPass,不是新的一次口述。
            if isStarting || phase == .recording || phase == .processing
                || Date().timeIntervalSince(lastKeyboardStartAt) < 0.5 {
                Self.recordTrace("桥 edit 忽略重复:isStarting=\(isStarting) phase=\(phase)")
                break
            }
            if !canStartRecordingInBackground, UIApplication.shared.applicationState != .active {
                Self.recordTrace("桥 edit 冷路径:交 openURL 起录 state=\(UIApplication.shared.applicationState.rawValue)")
                lastErrorNeedsForeground = true
                phase = .error("需要切换到 App 才能开始录音")
                publishKeyboardBridgeState()
                break
            }
            guard let baseText = KeyboardBridgeStore.snapshot().editBaseText, !baseText.isEmpty else {
                DiagLog.log("bridge", "桥 edit 请求缺少 editBaseText,忽略")
                break
            }
            if phase != .recording && phase != .processing {
                editingTarget = EditTarget(recordID: nil, baseText: baseText)
                lastKeyboardStartAt = Date()
                Task { await start(source: .bridge) }
            }
        }
    }

    private func publishKeyboardBridgeState() {
        // App 内独立口述/Action 语音输入不是键盘会话。仍发布心跳和后台可录能力，
        // 但桥状态必须保持 idle，不能把这些会话的文本暴露成 ready 结果。
        guard mode == .keyboard else {
            KeyboardBridgeStore.publishAppState(
                phase: .idle,
                liveText: "",
                cachedText: "",
                finalText: "",
                canStartRecordingInBackground: canStartRecordingInBackground
            )
            emitDarwinState(.idle)
            return
        }
        let bridgePhase: KeyboardBridgePhase
        let errorText: String
        switch phase {
        case .idle:
            bridgePhase = .idle
            errorText = ""
        case .recording:
            bridgePhase = .recording
            errorText = ""
        case .processing:
            bridgePhase = .processing
            errorText = ""
        case .done:
            bridgePhase = resultText.isEmpty ? .idle : .ready
            errorText = ""
        case .error(let message):
            bridgePhase = .error
            errorText = message
        }

        KeyboardBridgeStore.publishAppState(
            phase: bridgePhase,
            processingStage: phase == .processing ? processingStage : nil,
            liveText: liveText,
            cachedText: resultText,
            finalText: phase == .done ? resultText : "",
            errorText: errorText,
            needsForeground: bridgePhase == .error && lastErrorNeedsForeground,
            canStartRecordingInBackground: canStartRecordingInBackground,
            audioLevel: bridgePhase == .recording ? audioLevel : nil
        )
        emitDarwinState(bridgePhase)
    }

    /// 操作按钮捕捉的「录完 → 识别整理 → 入库」后台窗口。与键盘那份分开:键盘窗口挂在
    /// `mode == .keyboard` 上、生命周期跟着桥走,两者会互相覆盖。
    /// 到期回调只负责收尾登记,不打断正在跑的请求——真超时的话 `DictationPolicy.withTimeout`
    /// 那几道 12 秒封顶会先兜住。
    private func beginCaptureBackgroundWindow() {
        endCaptureBackgroundWindow()
        captureBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "ShallWeTalkCaptureProcessing"
        ) { [weak self] in
            DiagLog.log("capture", "后台执行窗口被系统收回")
            Task { @MainActor in self?.endCaptureBackgroundWindow() }
        }
    }

    private func endCaptureBackgroundWindow() {
        guard captureBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(captureBackgroundTaskID)
        captureBackgroundTaskID = .invalid
    }

    private func beginKeyboardBackgroundWindow() {
        guard mode == .keyboard else { return }
        if keyboardBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(keyboardBackgroundTaskID)
            keyboardBackgroundTaskID = .invalid
        }
        keyboardBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ShowWeTalkKeyboardBridge") { [weak self] in
            Task { @MainActor in self?.endKeyboardBackgroundWindow() }
        }
    }

    private func endKeyboardBackgroundWindow() {
        guard keyboardBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(keyboardBackgroundTaskID)
        keyboardBackgroundTaskID = .invalid
    }

    /// 起录来源:区分"前台化中的合法起录"(openURL/standalone/resume)与
    /// "键盘桥/Darwin 后台起录请求"(bridge/darwin)。后者在冷 + 非前台活跃时必须短路,
    /// 交给 voicepen://record 前台拉起后由 openURL 路径唯一起录,避免抢跑冷激活毒化会话。
    private enum StartSource {
        case openURL, bridge, darwin, standalone, resume
        var fromKeyboardBridge: Bool { self == .bridge || self == .darwin }
    }

    private func start(source: StartSource) async {
        guard !isStarting, phase != .recording, phase != .processing else { return }
        // 会议录音独占 AVAudioSession(见 yieldAudioForMeeting):会议进行中一律拒绝口述起录,
        // 而不是让两个 Recorder 实例争抢同一个音频会话。
        guard !MeetingRecordingController.shared.isActive else {
            DiagLog.log("start", "会议录音进行中，拒绝口述起录")
            if mode == .capture { actionKeyboardInsertionTarget = nil }
            return
        }
        isStarting = true
        defer { isStarting = false }
        DiagLog.log("start", "尝试起录 source=\(source) mode=\(mode) appState=\(UIApplication.shared.applicationState.rawValue) isHot=\(recorder.isHot)")

        guard await ensureMicrophoneAccess() else {
            DiagLog.log("start", "失败:麦克风权限被拒")
            phase = .error("请在系统设置中允许 Shall We Talk 使用麦克风")
            editingTarget = nil
            if mode == .capture { actionKeyboardInsertionTarget = nil }
            publishKeyboardBridgeState()
            return
        }

        lastErrorNeedsForeground = false
        // 冷路径守卫(扩宽:.inactive 与 .background 都算"非前台活跃")。
        // iOS 不允许 App 在后台发起全新录音('!rec');热会话下的"开始"只是恢复取样,属合法后台续录,放行。
        // 关键修复:此前只判 == .background,漏掉 URL 拉起瞬间的 .inactive(rawValue=1)——
        // 于是 cmdKick 送达的桥请求会抢在前台化之前冷激活会话(输入未就绪→"没有可用输入设备"),
        // 并毒化会话害得随后 openURL 前台起录 '!int'。故改判 != .active,且仅对键盘桥/Darwin 起录生效;
        // openURL/standalone/resume 本就在前台化,豁免此守卫(否则会挡掉合法冷启动)。
        if source.fromKeyboardBridge, !canStartRecordingInBackground,
           UIApplication.shared.applicationState != .active {
            os_log("键盘桥触发录音但 App 非前台活跃且无热会话,降级为跳转前台", log: Self.log, type: .info)
            DiagLog.log("start", "短路:非前台活跃+无热会话,发布 needsForeground(键盘应露出跳转 Link)")
            lastErrorNeedsForeground = true
            phase = .error("需要切换到 App 才能开始录音")
            publishKeyboardBridgeState()
            return
        }

        do { try await settings.prepareRelaySession() }
        catch {
            phase = .error(error.localizedDescription)
            DiagLog.log("relay", "起录前授权失败")
            publishKeyboardBridgeState()
            return
        }
        pendingClipboardCopy.clear()
        shortcutClipboardMessage = nil
        shortcutResultSession = UUID()
        shortcutResultText = nil
        liveText = ""; resultText = ""
        streamStartError = nil
        if mode != .keyboard { PendingTextStore.clear() }
        routedToTodo = false
        publishKeyboardBridgeState()
        levelEnvelope = 0; audioLevel = 0; visualLevel = 0; lastLevelPublishAt = .distantPast
        recordingStartedAt = Date(); lastVoiceAt = Date()
        hasDetectedSpeech = false
        voiceActivity.reset()
        vadSaysSpeaking = false
        voiceActivity.onSpeechState = { [weak self] speaking in
            Task { @MainActor in self?.ingestVoiceActivity(speaking) }
        }
        activeFieldKind = mode == .keyboard ? (KeyboardBridgeStore.snapshot().fieldKind ?? .general) : .general
        if activeFieldKind != .general {
            DiagLog.log("start", "输入框语义=\(activeFieldKind.rawValue) 整理策略=\(activeFieldKind.cleanupPolicy)")
        }

        CleanupService.prewarm(baseURL: settings.activeLLMBaseURL,
                               warmupURL: settings.cleanupWarmupURL,
                               authToken: settings.cleanupPrewarmToken)

        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        let usesWorker = settings.usesWorkerRelay
        let streamURL = usesWorker ? settings.workerRelayASRURL : URL(string: settings.volcWsURLString)
        let streamToken = usesWorker ? settings.activeWorkerToken : ""
        let streamAppID = usesWorker ? "" : settings.volcAppId
        let streamAccessToken = usesWorker ? "" : settings.volcAccessToken
        if let url = streamURL,
           usesWorker ? !streamToken.isEmpty : (!streamAppID.isEmpty && !streamAccessToken.isEmpty) {
            let session = VolcStreamingSession(
                wsURL: url, appId: streamAppID,
                accessToken: streamAccessToken,
                resourceId: settings.volcResourceId,
                hotwordsContext: settings.hotwordsContext(corrections: corrections, recentRecords: history.records),
                outputChineseVariant: settings.outputChineseVariant,
                protocolKind: usesWorker ? .nostream : .infer,
                bearerToken: usesWorker ? streamToken : nil,
                onPartial: { [weak self] partial in
                    Task { @MainActor in
                        guard let self else { return }
                        // partial 是云端连接建立以来累积的全量假设文本(不是逐句离散片段),
                        // 直接展示即可,不需要额外拼接确认前缀。
                        self.liveText = partial
                        self.publishKeyboardBridgeState()
                    }
                }
            )
            streamSession = session
            // VAD 与云端流式共用同一份 PCM。onChunk 只有一个槽位,所以在这里合流;
            // 没有流式会话时(下面的兜底路径)也要单独把 VAD 挂上,否则语音判定会失效。
            let feed: (Data) -> Void = { [weak session, weak self] chunk in
                session?.feed(chunk)
                self?.voiceActivity.feed(chunk)
            }
            recorder.onChunk = feed
            Task { [weak self] in
                do { try await session.start() } catch {
                    await MainActor.run {
                        guard let self, self.streamSession === session else { return }
                        self.streamSession = nil
                        self.streamStartError = error.localizedDescription
                        // 只摘掉流式那一路,VAD 仍需继续拿 PCM。
                        self.recorder.onChunk = { [weak self] chunk in self?.voiceActivity.feed(chunk) }
                        self.publishKeyboardBridgeState()
                    }
                }
            }
        } else {
            // 未配置流式识别:仍然要给 VAD 供 PCM,否则语音判定永远收不到数据。
            recorder.onChunk = { [weak self] chunk in self?.voiceActivity.feed(chunk) }
        }

        let levelHandler: (Float) -> Void = { [weak self] raw in
            Task { @MainActor in self?.ingestAudioLevel(raw) }
        }
        recorder.onLevel = levelHandler

        let usedHotPath = recorder.isHot
        do {
            // 起录耗时诊断:热直通应≈0ms(只清缓冲开闸);冷激活含 setActive+引擎启动+等输入路由,可能上百 ms
            let recStartT0 = CFAbsoluteTimeGetCurrent()
            try await startRecorderWithColdRetry(usedHotPath: usedHotPath)
            let recStartMs = (CFAbsoluteTimeGetCurrent() - recStartT0) * 1000
            phase = .recording
            if mode == .capture {
                ActionCaptureSessionStore.markRecording()
                // 走 ensureRecording 而不是 update:让「录音中」这个状态**只有一个写入者**。
                // 此前起录用 update(锚点=卡片创建时刻)、心跳用 ensureRecording(锚点=本次录音
                // 起点),两份状态永远不相等,心跳每一拍都判定"需要更新"并推一次 —— 一段 20 秒
                // 的口述就是几十次推送,而 ActivityKit 对更新频率是有限制的。
                CaptureLiveActivityController.shared.ensureRecording(
                    startedAt: recordingStartedAt,
                    message: Self.captureRecordingMessage
                )
            }
            hotSessionLastActiveAt = Date()
            publishKeyboardBridgeState()
            let sourceName = usedHotPath ? "热直通" : "冷激活"
            DiagLog.log("perf", "recorder.start=\(String(format: "%.0f", recStartMs))ms 路径=\(sourceName)")
            DiagLog.log("start", "起录成功 路径=\(sourceName) mode=\(mode)")
            // 键盘冷启动首次口述:录音已跑起来、App 稳定在前台、source view 已入窗口,
            // 这里才是画中画可能启动成功的最早时刻。放在起录成功之后不影响起录延迟。
            autoEnableKeyboardStandbyIfNeeded()
            // 冷启动自动返回宿主的第二个必要条件:麦克风真的跑起来了。PiP 与起录并行爬坡,
            // 谁后到就由谁触发;ColdReturnCoordinator 内部保证每次冷启动只跑一条梯子。
            // 返回失败(PiP 没建起来/系统不放行)时保持原有降级路径:留在 App 内录完,
            // 文字进桥,等用户回到宿主、键盘出现时插入(见 RecordView 的 .done 提示)。
            maybeStartColdReturn(trigger: "起录成功")
        } catch {
            let nsError = error as NSError
            let diagnostic = Self.diagnosticDescription(nsError)
            os_log("录音启动失败 %{public}@", log: Self.log, type: .error, diagnostic)
            DiagLog.log("start", "起录失败 路径=\(usedHotPath ? "热直通" : "冷激活") \(diagnostic)")
            recorder.onChunk = nil
            recorder.onLevel = nil
            phase = .error(Self.friendlyStartError(nsError, fallback: diagnostic))
            editingTarget = nil
            if mode == .capture {
                ActionCaptureSessionStore.clear()
                actionKeyboardInsertionTarget = nil
                CaptureLiveActivityController.shared.fail(message: "录音启动失败")
            }
            publishKeyboardBridgeState()
        }
    }

    /// 冷激活起录 + 一次瞬时失败重试。冷启动前台化的瞬间,输入路由常还没就绪(formatRate=0,
    /// Recorder 抛"没有可用的输入设备"),或被别的音频 App 短暂占用('!int');
    /// 退会话 → 短延时 → 重新激活再试一次,吸收这个窗口。热直通不重试(它只恢复取样,失败另有原因)。
    private func startRecorderWithColdRetry(usedHotPath: Bool) async throws {
        do {
            try recorder.start()
        } catch let e as NSError where !usedHotPath && Self.isTransientColdStartError(e) {
            DiagLog.log("start", "冷激活瞬时失败,退会话后 250ms 重试一次: \(Self.diagnosticDescription(e))")
            recorder.teardown()   // 含 setActive(false, .notifyOthersOnDeactivation),给别的音频 App 让路
            try? await Task.sleep(nanoseconds: 250_000_000)
            try recorder.start()
        }
    }

    /// 可重试的瞬时冷启动错误:输入未就绪(Recorder 自报 domain=Recorder)或被别的音频 App 占用
    /// ('!int' AVAudioSessionErrorCodeCannotInterruptOthers = 560557684)。
    private static func isTransientColdStartError(_ e: NSError) -> Bool {
        if e.domain == "Recorder" { return true }   // 没有可用的输入设备(formatRate=0 等)
        if e.code == 560557684 { return true }      // '!int' cannotInterruptOthers
        if e.code == -10868 { return true }         // kAudioUnitErr_FormatNotSupported:路由格式协商窗口
        return false
    }

    /// 把底层 OSStatus 翻成用户看得懂的话。Apple 对 '!int' 的精确定义是:
    /// App 在后台尝试激活一条非混音音频会话，不等同于“别的 App 占麦”。
    private static func friendlyStartError(_ e: NSError, fallback: String) -> String {
        if e.code == 560557684 { return "系统不允许 App 在后台重新激活麦克风，请回到 Shall We Talk 再试" }
        return "App 报错: \(fallback)"
    }

    /// 拼出 NSError 的 domain/code(+ OSStatus fourCC,若可打印)供键盘状态条与 os_log 定位真实原因,
    /// 避免"开始录音失败"这类无信息量文案掩盖具体故障。
    private static func diagnosticDescription(_ error: NSError) -> String {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: error.code))
        let bytes: [UInt8] = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        let fourCC = bytes.allSatisfy { (0x20...0x7e).contains($0) }
            ? String(bytes: bytes, encoding: .ascii)
            : nil
        let codeText = fourCC.map { "\(error.code) '\($0)'" } ?? "\(error.code)"
        return "\(error.domain) \(codeText): \(error.localizedDescription)"
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// 回放需要接管全局 AVAudioSession。键盘/操作按钮录音结束后 Recorder
    /// 会保留一段暖会话;若不先完整拆除，.playback 会话会与仍在运行的
    /// 输入引擎冲突，表现为按钮可点但没有声音。
    func prepareForAudioPlayback() {
        guard phase != .recording, phase != .processing else { return }
        if standbyEnabled, StandbyController.keepsRecorderHot {
            DiagLog.log("playback", "回放前暂停\(StandbyController.mechanismDisplayName)麦克风待命")
            deactivateStandby(status: "播放原音时已暂停待命", teardownWhenIdle: false)
            publishKeyboardBridgeState()
            return
        }
        guard recorder.isHot else { return }
        DiagLog.log("playback", "回放前拆除 Recorder 暖会话")
        recorder.teardown()
        if standbyEnabled {
            deactivateStandby(status: "播放原音时已暂停待命", teardownWhenIdle: false)
        }
        publishKeyboardBridgeState()
    }

    /// VAD 的语音状态回调。与 `ingestAudioLevel` 的 RMS 分支互斥:两者只有一个生效。
    private func ingestVoiceActivity(_ speaking: Bool) {
        guard phase == .recording else { return }
        vadSaysSpeaking = speaking
        guard speaking else { return }
        hasDetectedSpeech = true
        lastVoiceAt = Date()
    }

    private func ingestAudioLevel(_ raw: Float) {
        guard phase == .recording else { return }
        let coeff: Float = raw > levelEnvelope ? 0.4 : 0.15
        levelEnvelope += (raw - levelEnvelope) * coeff
        audioLevel = levelEnvelope

        // 键盘录音键波形的高频同步通道:节流到 0.1s,不搭常规 0.5s 桥轮询的车——
        // 那条轮询还兼着诊断日志、文字交付一整套工作,加速到 0.1s 会把那些也一起
        // 加速,风险和收益不成比例。这里只发一个字段,和 publishKeyboardBridgeState()
        // 里每 0.5s 的完整状态发布并存,互不冲突(后者顺带兜底把 audioLevel 清零)。
        //
        // 用途分开:`levelEnvelope`(攻 0.4/释 0.15)是判停/VAD 共用信号,刻意做保守的
        // 慢释放——防止说话中间的短促停顿被误判成说完了。这条平滑对判停正确,但拿去
        // 画波形观感就是"发糊"、swing 不出去(2026-08-18 用户反馈两轮"过于平缓")。
        // 波形展示单独跟一份更快的响度包络,不影响判停逻辑。
        let visualCoeff: Float = raw > visualLevel ? 0.75 : 0.35
        visualLevel += (raw - visualLevel) * visualCoeff
        if mode == .keyboard {
            let now = Date()
            if now.timeIntervalSince(lastLevelPublishAt) >= Self.levelPublishInterval {
                lastLevelPublishAt = now
                KeyboardBridgeStore.publishAudioLevel(visualLevel)
            }
        }

        // 语音判定优先用 Silero VAD(迟滞 + 最短语音时长,见 VoiceActivityPolicy)。
        // 模型不可用时退回原来的固定 RMS 阈值——绝不能两边都不更新 lastVoiceAt,
        // 否则静音一路累积到自动停录,等于录一次废一次。
        if !voiceActivity.isAvailable, raw > 0.18 {
            hasDetectedSpeech = true
            lastVoiceAt = Date()
        }
        let silence = Date().timeIntervalSince(lastVoiceAt)
        // VAD 静音自动停:含键盘模式(键盘模式下 finish() 会把识别文本经桥回填并保持热会话)。
        // 保留两道防过早停的闸门:必须已检测到说话(hasDetectedSpeech)+ 起录满 1.5s,
        // 避免用户还没开口就被切断。默认阈值 settings.vadSilenceSeconds = 4 秒。
        // 第三道闸门(2026-08-05):半句话中间的停顿把预算放宽到 2.5 倍——思考下半句怎么说
        // 的停顿不该被当成说完了(判定见 DictationPolicy.shouldAutoStop)。
        // 操作按钮捕捉用更长的阈值,给"再按一次结束"留出余地;其余入口沿用用户设置。
        let vadThreshold = mode == .capture ? Self.captureVADSilenceSeconds : settings.vadSilenceSeconds
        if settings.vadEnabled, hasDetectedSpeech,
           Date().timeIntervalSince(recordingStartedAt) > 1.5,
           DictationPolicy.shouldAutoStop(silence: silence,
                                          threshold: vadThreshold,
                                          transcriptSoFar: liveText) {
            DiagLog.log("vad", "静音\(String(format: "%.1f", silence))秒自动停 mode=\(mode) 阈值=\(Int(vadThreshold))s 句末=\(DictationPolicy.endsAtSentenceBoundary(liveText))")
            toggle()
        }
    }

    private func finish() async {
        // 幂等闸门:VAD 自动停时音量回调高频触发,可能在 phase 翻到 .processing 前抢跑两次 toggle→finish;
        // 非 .recording 直接返回,确保只走一次完整停录/识别流程。
        guard phase == .recording else { return }
        let isActionCapture = mode == .capture
        let lockedActionKeyboardTarget = isActionCapture ? actionKeyboardInsertionTarget : nil
        // 录完到入库这一段必须自己撑住后台执行时间。`recorder.stop()` 会停用 AVAudioSession,
        // 录音期间那份后台执行凭证随之消失(还可能连带带走挂在同一会话上的 PiP,见 §11),
        // 而后面 ASR / LLM / 落盘还要跑好几个网络请求。build 114 去掉预判性前台化之后 App
        // 真的留在了后台,这一段就会被系统挂起 —— 用户看到的是**卡在「正在识别」**
        // (2026-08-08 实测,连续两次复现)。改前不出问题只是因为那时 App 被顶到了前台。
        if mode == .capture { beginCaptureBackgroundWindow() }
        // 这一趟冷启动已经录完:无论有没有成功退回宿主,都不再欠"把用户送回去"这件事。
        coldKeyboardLaunch = false
        defer {
            if isActionCapture { actionKeyboardInsertionTarget = nil }
            endCaptureBackgroundWindow()
            restoreStandbyPresentationIfNeeded()
            autoEnableKeyboardStandbyIfNeeded()
        }
        // 端到端延迟打点起点:录音停止(用户松开录音键/VAD 触发)的时刻,
        // 下面各阶段的 metrics 字段都以此为锚点,详见 LatencyMetrics 的口径说明。
        let stopAt = Date()
        var metrics = LatencyMetrics()
        // 显式免切换待命覆盖入口差异；否则键盘保持 10 分钟、操作按钮保持 90 秒，
        // standalone 仍完整停机。
        let spokenAt = recordingStartedAt
        let recordingDuration = max(0, stopAt.timeIntervalSince(spokenAt))
        // SCK 只保持后台调度资格；真实音频始终来自 Recorder。
        // SCK 待命期保留预热引擎，下一次键盘点击只需打开已存在的取样闸门。
        // 保持 AVAudioSession 激活，避免连带掐掉刚建好的 SCK 流。
        let mechanismKeepsHot = standbyEnabled && StandbyController.keepsRecorderHot
        let shouldKeepHot = mechanismKeepsHot
            || (!standbyEnabled && (mode == .keyboard || mode == .capture))
        let wav = recorder.stop(keepHot: shouldKeepHot)
        if shouldKeepHot { hotSessionLastActiveAt = Date() }
        DiagLog.log("finish", "停录 mode=\(mode) source=Recorder keepHot=\(shouldKeepHot) isHot=\(recorder.isHot) wav=\(wav.count)B")
        recorder.onChunk = nil
        recorder.onLevel = nil
        levelEnvelope = 0; audioLevel = 0; visualLevel = 0; lastLevelPublishAt = .distantPast
        processingStage = .recognizing
        phase = .processing
        if mode == .capture {
            ActionCaptureSessionStore.clear()
            CaptureLiveActivityController.shared.update(stage: .processing, message: "正在识别…")
        }
        publishKeyboardBridgeState()

        // 每次录音先建立唯一记录 ID 并开始归档原音。这段必须放在有效样本
        // 守卫之前，否则麦克风只产生 WAV 头或极短样本时会既没音频也没记录。
        let recID = UUID()
        let audioArchiveTask = Task { await history.archiveAudio(wav, id: recID) }
        // WAV 头固定 44B。1,600B 约等于 50ms 的 16kHz/Int16 音频;低于此值
        // 说明 tap 根本没有取到有效麦克风缓冲,不应将空 WAV 送给 ASR 后只报“没有文字”。
        guard wav.count >= 1_644 else {
            streamSession?.cancel(); streamSession = nil
            DiagLog.log("finish", "麦克风未产生有效样本 wav=\(wav.count)B")
            phase = .error("未采集到麦克风声音，请重试；若仍失败，请在系统设置中重新允许麦克风权限")
            editingTarget = nil
            if mode == .capture {
                CaptureLiveActivityController.shared.fail(message: "没有录到有效声音")
            }
            let archivedAudioName = await audioArchiveTask.value
            appendFailedRecognition(
                id: recID, spokenAt: spokenAt, rawText: "",
                audioFileName: archivedAudioName, message: "未采集到有效麦克风样本")
            publishKeyboardBridgeState()
            return
        }
        // 输入框语义先于后续路由：搜索框里说满阈值也不该被分段编号（见 HostFieldKind）。
        // 最终路由必须等 ASR 定稿，才能让“第一/第二”等成组信号覆盖 10 秒阈值。
        let fieldPolicy = activeFieldKind.cleanupPolicy
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        let editTarget = editingTarget

        // 原音归档必须先于任何 ASR/LLM 请求启动。旧流程只在全部处理成功、
        // 历史记录已经 append 之后才异步归档，所以 ASR 抛错/空结果的早退分支
        // 根本不会走到存音频的代码。现在先启动本机原子写入，与 ASR 并行；
        // 任何成功/失败出口在建档前都 await 它，既不延迟流式会话收尾，也不丢原音。
        var recognizedRaw = ""

        do {
            let recognitionStartedAt = Date()
            let raw: String
            var recognitionSource: RecognitionSource = .cloud
            var streamingDiagnostics: ASRStreamingWorkRecord?
            if let session = streamSession {
                streamSession = nil
                do {
                    // session 本身现在就是单向流式连接(见 start(source:)),finish() 返回的
                    // 已经是定稿,不需要再额外发一次复核请求。
                    raw = try await session.finish()
                    metrics.asrFirstPartialMillis = session.diagnostics.firstPartialMillis
                    streamingDiagnostics = streamingWorkRecord(session: session, outcome: .completed)
                } catch {
                    DiagLog.log("asr", "流式收尾失败，切换整段识别: \(Self.diagnosticDescription(error as NSError))")
                    session.cancel()
                    metrics.asrFirstPartialMillis = session.diagnostics.firstPartialMillis
                    streamingDiagnostics = streamingWorkRecord(
                        session: session, outcome: .fellBack,
                        fallbackReason: error.localizedDescription)
                    raw = try await cloudBatchOrOnDevice(wav: wav, source: &recognitionSource)
                }
            } else {
                streamingDiagnostics = streamingWorkRecord(
                    session: nil,
                    outcome: streamStartError == nil ? .unavailable : .fellBack,
                    fallbackReason: streamStartError ?? "录音期间没有可用的流式会话")
                raw = try await cloudBatchOrOnDevice(wav: wav, source: &recognitionSource)
            }
            recognizedRaw = raw
            metrics.asrFinalMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            DiagLog.log("perf", "ASR 终稿用时=\(String(format: "%.1f", Date().timeIntervalSince(recognitionStartedAt)))s chars=\(DictationPolicy.meaningfulCharacterCount(raw))")
            // 整段只有"嗯""呃"这类纯发声停顿时同样按"没有识别到内容"处理:整理后必然
            // 为空,不该插入任何文字,也不值得为它发一次 LLM 请求。
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !DictationPolicy.isPureFilledPause(raw) else {
                DiagLog.log("cleanup", "无可插入内容(空或仅含纯发声停顿),跳过整理 raw=\(raw.count)字")
                liveText = ""
                phase = .error("没有识别到内容")
                editingTarget = nil
                if mode == .capture {
                    CaptureLiveActivityController.shared.fail(message: "没有识别到内容")
                }
                let archivedAudioName = await audioArchiveTask.value
                appendFailedRecognition(
                    id: recID, spokenAt: spokenAt, rawText: raw,
                    audioFileName: archivedAudioName, message: "没有识别到内容")
                publishKeyboardBridgeState()
                return
            }

            // 修改模式(语音二次修改-执行方略.md v2 §5):第二次口述的 ASR 原文绝不过
            // 整理 prompt(会把描述式用字"顺"成通顺句,指令当场失真),直接作为修改要求
            // 送进 EditPass。整段跳过下面的整理路由、待办提取、新建历史记录三块——
            // 修改结果写回同一条既有记录,不是一次新的口述。
            if let target = editTarget {
                let archivedAudioName = await audioArchiveTask.value
                await applyEdit(
                    target: target, instruction: raw, stopAt: stopAt, metrics: &metrics,
                    audioFileName: archivedAudioName)
                return
            }

            // 普通输入框先看 ASR 成组列举信号、再看真实录音时长；搜索框等强制短路由
            // 与邮箱/网址等跳过整理路由保持原安全策略，不被文本信号覆盖。
            let cleanupRoute: CleanupPromptRoute
            switch fieldPolicy {
            case .forceShort, .skipCleanup:
                cleanupRoute = .homophoneOnly
            case .byDuration:
                cleanupRoute = DictationPolicy.cleanupPromptRoute(
                    recordingDuration: recordingDuration,
                    transcript: raw,
                    fullCleanupThresholdSeconds: settings.fullCleanupThresholdSeconds,
                    forceShortPrompt: settings.cleanupLevel == .light)
            }
            let meaningfulCount = DictationPolicy.meaningfulCharacterCount(raw)
            var clean = raw
            var cleanupFellBackToRaw = false
            var cleanupStatus: CleanupStatus = .skipped
            processingStage = .cleaning
            publishKeyboardBridgeState()
            // 记录与待办是两个独立产出,各用各的 prompt(2026-08-06 用户明确要求):
            // 这里只负责「记录」那一份——成组列举信号优先，否则按录音时长走短/长整理；
            // capture 也不按结果去向覆盖这项裁决。
            // 「待办」那一份改由下面的 extractTodos 单独跑一次待办 prompt,两者互不污染。
            if mode == .capture {
                let message = cleanupRoute == .homophoneOnly ? "正在纠正识别…" : "正在整理…"
                CaptureLiveActivityController.shared.update(stage: .processing, message: message)
            }
            DiagLog.log(
                "cleanup",
                "开始 LLM 整理 route=\(cleanupRoute) duration=\(String(format: "%.1f", recordingDuration))s threshold=\(Int(settings.fullCleanupThresholdSeconds))s count=\(meaningfulCount) mode=\(mode)")

            if fieldPolicy == .skipCleanup {
                // 邮箱、网址、数字与电话框:整理只会添乱(把口述的网址"顺"成一句话、
                // 给电话号码补标点)。直接用 ASR 原文,省掉一次请求与全部整理延迟。
                clean = raw
                DiagLog.log("cleanup", "输入框语义=\(activeFieldKind.rawValue),跳过 LLM 整理,直接使用 ASR 原文")
            } else if settings.redundantCleanupGateEnabled,
                      DictationPolicy.cleanupIsRedundant(
                          raw, dictionaryWords: settings.dictionaryWords,
                          corrections: corrections, customInstruction: settings.customPrompt) {
                // 空转守门员(见 `DictationPolicy.cleanupIsRedundant`)。上面那个分支按**输入框**
                // 跳过,这个按**文本本身**跳过:短、无停顿音、无重复、无列举信号、词典没说岔的
                // ASR 终稿,整理有 91% 的概率原样返回。2026-08-16 快照实测这类占 52%,
                // 每次省下 0.87 秒——它是端到端 p50 里最大的一块可回收时间。
                //
                // 放行错了只是少删一个"嗯"那个量级(全样本整理前后中位字数变化 −1 字);
                // 拦错了就是现状。所以这里对不确定的一律拦下,只放行几乎必然空转的。
                clean = raw
                DiagLog.log("cleanup", "空转守门员放行,跳过 LLM 整理 count=\(meaningfulCount) route=\(cleanupRoute)")
            } else {
                // native nostream 先取得完整终稿，再只发一次 LLM 请求。短口述不要求结构化；
                // 长口述把分段/编号规则合并在同一 prompt 内，不再运行旧分段器或第二次通读。
                let prompt = PromptBuilder.buildDictation(
                    route: cleanupRoute,
                    customInstruction: settings.customPrompt,
                    dictionary: settings.dictionaryWords,
                    corrections: corrections)
                let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                         apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
                let tokenBox = MillisBox()
                let usageBox = UsageBox()
                let firstPassStartedAt = Date()
                cleanupStatus = .succeeded
                let displayRequestID = UUID()
                cleanupDisplayRequestID = displayRequestID
                let operation: @Sendable () async -> CleanupAttempt = { [weak self] in
                    do {
                        let result = try await llm.cleanStream(
                            raw: raw, systemPrompt: prompt, onFirstToken: {
                                if tokenBox.value == nil {
                                    tokenBox.value = Int(Date().timeIntervalSince(stopAt) * 1000)
                                }
                            }, onUsage: { usageBox.value = $0 },
                            forbidsNewNumbers: cleanupRoute == .homophoneOnly
                        ) { p in
                            Task { @MainActor in
                                guard let self, self.cleanupDisplayRequestID == displayRequestID else { return }
                                self.liveText = p
                            }
                        }
                        return result.isEmpty ? .failed : .success(result)
                    } catch {
                        DiagLog.log("cleanup", "整理请求失败,历史记录保留 ASR 原文: \(error.localizedDescription)")
                        return .failed
                    }
                }
                let startedAt = Date()
                switch await DictationPolicy.withTimeout(operation: operation) {
                case .success(let result)?:
                    clean = result
                case .failed?, nil:
                    clean = raw
                    cleanupFellBackToRaw = true
                    cleanupStatus = .failed
                }
                cleanupDisplayRequestID = nil
                metrics.llmFirstTokenMillis = tokenBox.value
                metrics.apply(usageBox.value)
                metrics.firstCleanupPass = cleanupPassMetrics(
                    startedAt: firstPassStartedAt, firstTokenMillis: tokenBox.value,
                    completedAt: Date(), usage: usageBox.value, stopAt: stopAt)
                let routeName: String
                switch cleanupRoute {
                case .homophoneOnly: routeName = "短口述单次整理"
                case .full: routeName = "长口述单次完整整理"
                case .explicitEnumeration: routeName = "显式列举强化整理"
                }
                DiagLog.log("cleanup", "\(routeName)用时=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s\(cleanupFellBackToRaw ? "(超时/失败回退原文)" : "")")
            }
            if clean.isEmpty {
                clean = raw
                cleanupFellBackToRaw = true
                cleanupStatus = .failed
            }
            // 确定性替换兜底:纠错对已经喂过整理 prompt,但那是给模型的自然语言指令,
            // 是否严格执行、是否不区分大小写都不保证,且"轻"整理档完全不过模型——
            // 这里补一道字符串级别的替换,保证用户明确要求的替换词组任何路径下都生效。
            // 但整理请求失败时必须保留未经整理的 ASR 原文,不能再经过这一步改变原文。
            if !cleanupFellBackToRaw {
                clean = ManualCorrections.apply(to: clean, pairs: corrections)
            } else {
                DiagLog.log("cleanup", "整理失败,历史记录 cleanText 使用未经整理的 ASR 原文")
            }
            metrics.cleanupCompleteMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            if let promptTokens = metrics.promptTokens {
                // 命中率决定首字延迟,而首字延迟是短口述等待时间的大头;
                // 没有这行,prompt 段序的调整就无法复盘。
                let rate = metrics.promptCacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "未知"
                DiagLog.log("cleanup",
                            "prompt token=\(promptTokens) 命中缓存=\(metrics.cachedPromptTokens ?? 0)(\(rate))")
            }
            logCleanupPassStats(metrics)

            // 待办与文字投递是两个独立决策,不是互斥路由:
            // - capture:始终复制到系统剪贴板;是否建待办看 actionForceTodo——
            //   Action Key 一律强制建待办,「语音记录」捷径仍按触发词分流;
            // - todoCapture:待办页明确发起,强制建待办;
            // - standalone:命中触发词则建待办,否则输出普通文字;
            // - keyboard:始终回填外部输入框;若同时命中触发词,再额外同步建待办。
            // 诊断:自检路由判断——mode 在这一刻是否仍是发起时的值(若被桥请求悄悄改写会在此现形)
            // 原文与整理稿都要看:走了待办强整理时,整理稿里的触发词已被去掉(判定要靠原文);
            // 没走强整理时,轻量同音纠错可能刚好把误识的"提现我"修回"提醒我"(判定要靠整理稿)。
            let hitsTrigger = IntentRouter.shouldCreateTodo(rawText: raw, cleanedText: clean)
            let shouldCreateTodo = mode == .todoCapture || hitsTrigger || (mode == .capture && actionForceTodo)
            let shouldDeliverText = mode == .keyboard || mode == .capture || !shouldCreateTodo
            let deliveryText = activeFieldKind.textForDelivery(clean)
            var keyboardDeliveryPublished = true
            var captureClipboardCopied = true
            var actionKeyboardDeliveryPublished = false
            DiagLog.log("route", "路由判断 mode=\(mode) 强制待办=\(actionForceTodo) 触发词=\(hitsTrigger) 建待办=\(shouldCreateTodo) 投递文字=\(shouldDeliverText)")

            var todoResultText = ""
            if shouldCreateTodo {
                // 待办条目一律单独跑一次待办 prompt,输入是上面整理好的记录正文。
                // 两条不再共用一份结果:记录保留完整语义(含"提醒我"),待办才做条目化
                // (去套话、多件事拆行)。也不再看时长阈值——此前短口述是 items = [clean],
                // 整段带着"提醒我"原样入库,正是 2026-08-06 用户反馈的问题。
                if mode == .capture || mode == .todoCapture {
                    CaptureLiveActivityController.shared.update(stage: .processing, message: "正在整理待办…")
                }
                let todoStartedAt = Date()
                let todoLLM = CleanupService(baseURL: settings.activeLLMBaseURL,
                                             apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
                let items = await IntentRouter.extractTodos(
                    from: clean, llm: todoLLM, dictionary: settings.dictionaryWords)
                DiagLog.log("route", "待办提取用时=\(String(format: "%.1f", Date().timeIntervalSince(todoStartedAt)))s 条数=\(items.count)")
                // 日期换算必须使用真正的开始说话时间，不能用 LLM 完成时间。
                // 如果整理恰好跨过凌晨 3 点，仍能按用户开口时的语义日期解析。
                let plans = items.map { TodoDateResolver.resolve($0, spokenAt: spokenAt) }
                let normalizedItems = zip(items, plans).map { text, plan in plan?.normalizedText ?? text }
                let addedTodos = todos.add(normalizedItems, sourceRecordID: recID, sourceRawText: raw)
                enqueueCalendarUpdates(todos: addedTodos, plans: plans)
                DiagLog.log("route", "已加入待办 \(normalizedItems.count) 条")
                todoResultText = normalizedItems.joined(separator: "\n")
                routedToTodo = true
            }

            if shouldDeliverText {
                resultText = deliveryText
                if mode == .keyboard {
                    // 只允许键盘会话投递，并绑定 App 已处理的具体 request ID。
                    // App 内 standalone 口述只进入历史/结果页，绝不写入键盘共享槽。
                    let requestID = KeyboardBridgeStore.snapshot().handledRequestID
                    keyboardDeliveryPublished = PendingTextStore.push(deliveryText, requestID: requestID)
                    if !keyboardDeliveryPublished {
                        DiagLog.log("insert", "交付 payload 发布失败 requestID=\(requestID)")
                    }
                    // 键盘遮挡故障(§11.1a)只在回填之后发作,而扩展写的 [KB][kbGeom] 采样
                    // 要靠主 App 镜像才能被 devicectl 取回。暖路径下 App 全程不切前台、
                    // scenePhase 不变,原来那处"切后台时镜像"永远不触发,现场因此拿不到。
                    // 延后 3 秒,等键盘的三次定点采样(0 / 0.3 / 1.2s)全部落盘后再镜像。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        DiagLog.mirrorToAppContainer()
                    }
                } else if mode == .capture {
                    // Action 交付始终保留一份系统剪贴板副本；与此同时，
                    // 若起录时锁定的 Shall We Talk 输入文档此刻仍活跃，
                    // 再通过 request-bound 事务槽让键盘扩展直接插入。
                    PendingTextStore.clear()
                    captureClipboardCopied = PendingTextStore.copyToSystemPasteboard(deliveryText)
                    if !actionForceTodo {
                        if captureClipboardCopied {
                            pendingClipboardCopy.clear()
                            shortcutClipboardMessage = "已复制，回到原输入框粘贴"
                        } else {
                            pendingClipboardCopy.enqueue(deliveryText)
                            shortcutClipboardMessage = "文字已保存，请返回 App 完成复制"
                        }
                    }
                    // 待命机制决定进程有没有前台资格,而前台资格正是通用剪贴板的闸门:
                    // 2026-09-01 真机实测「待命开=能写、待命关=写不了」。所以只记成败不够,
                    // 必须同时记下当时是哪套待命在撑着,否则日志无法归因。
                    // PiP 待命已实测可写;SCK 待命是否同样给通行证是本次要验证的问题
                    // (SCK 无可见窗口,PiP 的资格很可能正来自"有可见 UI")。
                    DiagLog.log("clipboard",
                                "Action 剪贴板交付 结果=\(captureClipboardCopied ? "成功" : "失败") "
                                + "待命机制=\(StandbyController.mechanismName) "
                                + "待命中=\(StandbyController.shared.isActive) "
                                + "appState=\(UIApplication.shared.applicationState.rawValue)")
                    if let target = lockedActionKeyboardTarget,
                       let requestID = KeyboardBridgeStore.publishActionKeyboardDelivery(
                        deliveryText, to: target
                       ) {
                        actionKeyboardDeliveryPublished = true
                        DiagLog.log("insert", "Action 结果已发布给当前 Shall We Talk 键盘 requestID=\(requestID)")
                    } else if lockedActionKeyboardTarget != nil {
                        DiagLog.log("insert", "Action 录音期间键盘或输入框已切换，取消自动插入")
                    }
                } else {
                    PendingTextStore.clear()
                }
            } else {
                resultText = todoResultText.isEmpty ? clean : todoResultText
                PendingTextStore.clear()
            }
            metrics.totalMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
            DiagLog.log("perf", "端到端耗时 首包=\(metrics.asrFirstPartialMillis.map { "\($0)ms" } ?? "-") "
                + "asr终稿=\(metrics.asrFinalMillis.map { "\($0)ms" } ?? "-") "
                + "整理首字=\(metrics.llmFirstTokenMillis.map { "\($0)ms" } ?? "-") "
                + "整理完成=\(metrics.cleanupCompleteMillis.map { "\($0)ms" } ?? "-") "
                + "总计=\(metrics.totalMillis.map { "\($0)ms" } ?? "-")")
            let archivedAudioName = await audioArchiveTask.value
            let record = DictationRecord(
                id: recID, date: spokenAt, rawText: raw, cleanText: clean, finalText: nil,
                audioFileName: archivedAudioName, metrics: metrics,
                recognitionSource: recognitionSource,
                // 端侧整段批量转写已删除(2026-08-16,分歧检测/虚线标注功能一并下线),
                // 不再产出这份数据;字段保留只是不破坏历史记录的存储结构。
                onDeviceText: nil,
                streamingDiagnostics: streamingDiagnostics,
                cleanupStatus: cleanupStatus, recordingDuration: recordingDuration)
            history.append(record)
            if mode == .capture && !actionForceTodo { shortcutResultText = resultText }
            if settings.iCloudSyncEnabled {
                // iCloud 文件写入也可能等待网络/文件协调，不能在 MainActor 上同步执行。
                Task.detached(priority: .utility) {
                    CloudHistorySync.push(record)   // 仅文本入云;audioFileName 不同步(音频太大,仅本机可播)
                }
                lastCloudSyncStatus = "已同步最新历史到 iCloud"
            }
            refreshAutoDictionary()
            liveText = ""
            if mode == .keyboard && !keyboardDeliveryPublished {
                phase = .error("文字交付暂时失败，请重试")
            } else if mode == .capture && !captureClipboardCopied {
                phase = .error(shortcutClipboardMessage ?? "记录已保存，但复制到剪贴板失败")
            } else {
                phase = .done
            }
            if mode == .capture {
                if captureClipboardCopied {
                    let message: String
                    if actionKeyboardDeliveryPublished {
                        message = shouldCreateTodo
                            ? "已发送到当前输入框，并加入待办与记录"
                            : "已发送到当前输入框，并保存到记录"
                    } else {
                        message = shouldCreateTodo
                            ? "已复制，并加入待办与记录"
                            : "已复制到剪贴板，并保存到记录"
                    }
                    CaptureLiveActivityController.shared.complete(message: message)
                } else {
                    CaptureLiveActivityController.shared.fail(message: shortcutClipboardMessage ?? "文字已保存，但复制失败")
                }
                // 收尾:震两下。与起录的一下区分开,不看屏幕也能判断处在哪一端。
                if UIApplication.shared.applicationState != .active {
                    BackgroundCue.buzz(times: 2)
                }
            }
            publishKeyboardBridgeState()
            // The scene may have become active during processing, when the
            // activation callback intentionally deferred its retry.
            if mode == .capture && !captureClipboardCopied && !actionForceTodo {
                retryShortcutClipboardCopyIfActive()
            }
        } catch {
            let message = "处理失败: \(error.localizedDescription)"
            let archivedAudioName = await audioArchiveTask.value
            liveText = ""
            phase = .error(message)
            editingTarget = nil
            appendFailedRecognition(
                id: recID, spokenAt: spokenAt, rawText: recognizedRaw,
                audioFileName: archivedAudioName, message: message)
            if mode == .capture {
                CaptureLiveActivityController.shared.fail(message: "处理失败，请重试")
            }
            publishKeyboardBridgeState()
        }
    }

    /// ASR 或整理阶段失败时仍建立一条可回听的本机记录。
    /// 该记录不上传 iCloud（云端本来就不同步音频），用户可在历史页
    /// 直接播放原音，或点“重新识别”复用现有的整段云端识别流程。
    private func appendFailedRecognition(
        id: UUID, spokenAt: Date, rawText: String,
        audioFileName: String?, message: String
    ) {
        let record = DictationRecord(
            id: id, date: spokenAt, rawText: rawText, cleanText: rawText, finalText: nil,
            audioFileName: audioFileName, recognitionError: message)
        history.append(record)
        DiagLog.log(
            "audioArchive",
            "识别失败记录已建档 id=\(id.uuidString.suffix(8)) audio=\(audioFileName ?? "nil")")
    }

    /// 修改模式的收尾:调用 `EditPass`,按 `EditGuard` 的判定分四支处理,写回历史。
    /// 不抛出——网络/请求失败与"判定不出"同等对待,红线是原稿一字不动。
    ///
    /// 2026-08-19 起不再传入 `corrections`(纠错对块):真机复现+隔离测试证实,一旦纠错对块
    /// 出现在修改模式的 system prompt 里,模型会把"只有完整命中已知错误片段才替换"这条
    /// 强约束泛化到当次修改指令本身,导致对不在纠错对列表里的新指令过度保守、原文照抄
    /// 输出(EditGuard 判定为 `unchanged`)。同一原文+同一指令,去掉纠错对块后模型能正确
    /// 完成修改;只去掉词典块不影响,复现下来问题专属纠错对块。修改模式的场景本就是
    /// "用户当场把正确写法再说一遍",不依赖历史纠错对,词典(专名拼写权威)予以保留。
    private func applyEdit(target: EditTarget, instruction: String,
                           stopAt: Date, metrics: inout LatencyMetrics,
                           audioFileName: String?) async {
        processingStage = .cleaning
        publishKeyboardBridgeState()
        let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                 apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
        let tokenBox = MillisBox()
        let usageBox = UsageBox()
        let candidateBox = TextBox()
        let startedAt = Date()
        let outcome: EditOutcome
        do {
            outcome = try await EditPass.run(
                original: target.baseText, instruction: instruction, llm: llm,
                dictionary: settings.dictionaryWords,
                onFirstToken: {
                    if tokenBox.value == nil { tokenBox.value = Int(Date().timeIntervalSince(stopAt) * 1000) }
                }, onUsage: { usageBox.value = $0 }
            ) { [weak self] partial in
                candidateBox.value = partial
                Task { @MainActor in self?.liveText = partial }
            }
        } catch {
            DiagLog.log("edit", "修改请求失败: \(Self.diagnosticDescription(error as NSError))")
            outcome = .noEdit
        }
        // 诊断用:原文/指令/模型原始输出三者留痕,才能在 unchanged/noEdit 时回答
        // "为什么没改动"——这两种结果本身不带候选字符串,只能靠这里补一份。
        DiagLog.log(
            "edit",
            "修改详情 原文=\"\(target.baseText)\" 指令=\"\(instruction)\" 模型输出=\"\(candidateBox.value)\""
        )
        metrics.llmFirstTokenMillis = tokenBox.value
        metrics.apply(usageBox.value)
        metrics.totalMillis = Int(Date().timeIntervalSince(stopAt) * 1000)
        let outcomeLabel: String
        switch outcome {
        case .applied: outcomeLabel = "applied"
        case .noEdit: outcomeLabel = "noEdit"
        case .unchanged: outcomeLabel = "unchanged"
        case .flaggedLargeChange: outcomeLabel = "flaggedLargeChange"
        }
        DiagLog.log("edit", "修改模式用时=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s 结果=\(outcomeLabel)")

        if let recordID = target.recordID {
            // P0:主 App 结果页,落库到既有历史记录,交给 lastEditOutcome banner 展示。
            switch outcome {
            case .applied(let text), .flaggedLargeChange(let text):
                history.pushRevision(id: recordID, instructionRaw: instruction,
                                     before: target.baseText, after: text,
                                     audioFileName: audioFileName)
                refreshAutoDictionary()
                if settings.iCloudSyncEnabled,
                   let record = history.records.first(where: { $0.id == recordID }) {
                    Task.detached(priority: .utility) { CloudHistorySync.push(record) }
                }
                resultText = text
            case .noEdit, .unchanged:
                history.removeUnreferencedAudio(named: audioFileName)
                break
            }
            lastEditOutcome = EditOutcomeEntry(recordID: recordID, outcome: outcome)
        } else {
            // P1:键盘态,不对应任何历史记录。不管哪种结果都要经桥交付回宿主输入框——
            // .noEdit/.unchanged 原样推回 baseText,靠 commitHostMarkedText 的
            // "整段替换成同样内容再 unmark"语义等价于"什么也没变,只是转正",
            // 不需要额外的"撤销"信号。
            let delivered: String
            switch outcome {
            case .applied(let text), .flaggedLargeChange(let text): delivered = text
            case .noEdit, .unchanged: delivered = target.baseText
            }
            resultText = delivered
            if mode == .keyboard {
                let requestID = KeyboardBridgeStore.snapshot().handledRequestID
                if !PendingTextStore.push(delivered, requestID: requestID) {
                    DiagLog.log("edit", "修改交付 payload 发布失败 requestID=\(requestID)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    DiagLog.mirrorToAppContainer()
                }
            }
            history.removeUnreferencedAudio(named: audioFileName)
        }
        editingTarget = nil
        liveText = ""
        phase = .done
        publishKeyboardBridgeState()
    }

    /// 进入修改模式并直接起录:记下要改哪一条记录、当前稿是什么,随即走既有
    /// `mode = .standalone` 起录流程(P0 只在主 App 内录音,不涉及键盘桥的冷启动守卫)。
    /// 2026-08-19 起改为一步到位——此前分两步(先点"语音修改"进入待录态,再点底部
    /// 录音键才真正开始),用户反馈多余,合并成一次点击。调用方(MemoRow 的
    /// "语音修改"按钮)已在 `recordingActive` 时禁用,故这里不必再防重入。
    func beginEdit(recordID: UUID) {
        guard let record = history.records.first(where: { $0.id == recordID }) else { return }
        editingTarget = EditTarget(recordID: recordID, baseText: record.finalText ?? record.cleanText)
        lastEditOutcome = nil
        Task { await start(source: .standalone) }
    }

    func cancelEdit() {
        editingTarget = nil
    }

    /// 结果 banner 关闭/超时后清掉上一次修改的展示状态,不影响已经落库的 finalText/revisions。
    func dismissEditOutcome() {
        lastEditOutcome = nil
    }

    /// 撤销最近一次语音修改。与 `updateHistoryFinalText` 同一收尾模式:刷新词典 + 有
    /// iCloud 时异步推送。
    func undoLastEdit(recordID: UUID) {
        guard history.undoLastRevision(id: recordID) else { return }
        refreshAutoDictionary()
        guard settings.iCloudSyncEnabled,
              let record = history.records.first(where: { $0.id == recordID }) else { return }
        Task.detached(priority: .utility) { CloudHistorySync.push(record) }
    }

    /// 键盘唤起录音时自动开启「免切换待命」(2026-08-03 用户要求)。
    ///
    /// 目标场景:冷启动后第一次从键盘点语音键——键盘发现无热会话且 App 不在前台,露出
    /// 跳转 Link,用户点一下把 App 拉到前台经 `voicepen://record` 起录。就在这一次口述
    /// 期间把画中画待命建起来,用户说完就已处于待命,之后再点键盘不必再跳。
    ///
    /// **挂在"录音刚开始"而不是"录完之后"**,两个硬原因:
    /// ① `requestStartFromUserAction()` 内部就是真正调 `startPictureInPicture()` 的地方,
    ///    它要求 `isPictureInPicturePossible`,而这需要常驻 source view 已经入窗口。冷启动
    ///    刚 openURL 那一刻界面还没布局完,必然拿不到;录音已经跑起来时 App 稳定在前台、
    ///    view 已入窗口,才是它可能为真的时刻。
    /// ② 录完再开会让"第一次点键盘"这一趟白跑——用户要的是这一次就进入待命。
    ///
    /// 传 `duringRecording: true`,让 `activateStandby()` 不去拆录音引擎。
    /// 仍可能静默跳过(不算失败,诊断日志写明是哪一条):App 不在前台(键盘走暖会话直录
    /// 时如此,但那种情况本就不需要待命)、或画中画控制器仍未就绪。
    private func autoEnableKeyboardStandbyIfNeeded() {
        // 偏好被刻意关掉后,键盘口述不得再把它偷偷打开——否则"关闭"等于没关(2026-08-06)。
        guard settings.standbyPreferredOn else { return }
        guard !MeetingRecordingController.shared.isActive else { return }
        guard mode == .keyboard, !standbyEnabled, !standbyIsStarting else { return }
        guard standbyArmRetryTask == nil else { return }
        startStandbyArmAttempts(reason: "键盘唤起录音")
    }

    /// 建待命的共用重试机。首次尝试失败最常见的两个原因都是"还没准备好"而不是"不行":
    /// 冷启动前台化尚未走完(2026-08-04 实测三次全是 .inactive/.background),或常驻 source
    /// view 还没入窗口导致 isPictureInPicturePossible 为 false。小步重试,不阻塞录音。
    private func startStandbyArmAttempts(reason: String) {
        guard !MeetingRecordingController.shared.isActive else {
            Self.recordTrace("会议录音中，取消待命重试 reason=\(reason)")
            return
        }
        loggedBackgroundSkip = false
        if tryArmStandby(reason: reason) { return }
        standbyArmRetryTask = Task { @MainActor [weak self] in
            defer { self?.standbyArmRetryTask = nil }
            for _ in 0..<40 {                                  // 最多 ~10 秒
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.settings.standbyPreferredOn,
                      !self.standbyEnabled, !self.standbyIsStarting,
                      !MeetingRecordingController.shared.isActive else { return }
                if self.tryArmStandby(reason: reason) { return }
            }
            Self.recordTrace("自动开启:重试窗口内始终不满足条件,放弃本次 reason=\(reason)")
        }
    }

    /// 冷路径生命周期打点。2026-08-04 排查"返回慢 4–6 秒"时发现没有任何 App 状态迁移记录,
    /// 只能靠 PiP 日志倒推;这里把 openURL → active → background 的真实间隔记下来。
    ///
    /// `didBecomeActive` 同时是**事件驱动的 arm 时机**:AVKit 在 `.inactive` 期间会以 -1001
    /// 拒绝 `startPictureInPicture`,只有真正 active 之后才接受。挂在事件上比 250ms 轮询
    /// 少等半拍,也避免多打一次注定失败的启动请求。
    private func startColdPathLifecycleObserver() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logColdPathMilestone("didBecomeActive")
                self.retryShortcutClipboardCopyIfActive()
                self.armKeyboardStandbyOnActivation()
            }
        }
        // 手动右滑回宿主 与 系统自动退回 都会走 resign→background。记下 resign 的时刻,
        // 配合"全程不碰屏幕"的测试条件,就能判断退后到底是谁触发的。
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.logColdPathMilestone("willResignActive") }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.logColdPathMilestone("didEnterBackground") }
        }
    }

    /// `.active` 是 AVKit 唯一肯接受 `startPictureInPicture` 的状态,所以拿到这个通知就是
    /// 冷启动路径上最早的合法 arm 时机。不走 `autoEnableKeyboardStandbyIfNeeded()` 是因为
    /// 它有 `standbyArmRetryTask == nil` 的守卫——250ms 重试循环此刻正在跑,会把这次直接吞掉,
    /// 白白多等半拍。
    private func armKeyboardStandbyOnActivation() {
        guard settings.standbyPreferredOn else { return }
        guard !MeetingRecordingController.shared.isActive else { return }
        guard coldKeyboardLaunch, mode == .keyboard else { return }
        guard !standbyEnabled, !standbyIsStarting else { return }
        guard tryArmStandby(reason: "冷启动 didBecomeActive") else { return }
        standbyArmRetryTask?.cancel()
        standbyArmRetryTask = nil
    }

    private func logColdPathMilestone(_ name: String) {
        guard let startedAt = coldLaunchStartedAt else { return }
        let ms = Date().timeIntervalSince(startedAt) * 1000
        Self.recordTrace("[冷路径] \(name) +\(String(format: "%.0f", ms))ms "
                         + "phase=\(phase) standby=\(standbyEnabled) "
                         + "PiP=\(StandbyController.shared.isActive)")
    }

    /// Cold return needs the selected standby mechanism, current request and real audio.
    private func maybeStartColdReturn(trigger: String) {
        guard settings.coldReturnEnabled, coldKeyboardLaunch, mode == .keyboard,
              phase == .recording, standbyEnabled, StandbyController.shared.isActive,
              let request = coldReturnRequest else { return }
        coldKeyboardLaunch = false
        Task { @MainActor [weak self] in
            await ColdReturnCoordinator.attemptReturn(
                requestID: request.id, target: request.target, requestAt: request.at, reason: trigger,
                isStillEligible: { [weak self] in
                    guard let self else { return false }
                    return self.phase == .recording && self.mode == .keyboard &&
                        self.coldReturnRequest?.id == request.id && self.settings.coldReturnEnabled &&
                        StandbyController.shared.isActive
                },
                hasFreshAudio: { [weak self] in
                    guard let self else { return false }
                    return self.recorder.isEngineLive && self.recorder.capturedByteCount > 0
                }
            )
        }
    }

    /// 返回 true 表示"已经发出启动请求",不需要再重试。
    private func tryArmStandby(reason: String) -> Bool {
        guard !MeetingRecordingController.shared.isActive else {
            Self.recordTrace("会议录音中，拒绝待命请求 reason=\(reason)")
            return false
        }
        let state = UIApplication.shared.applicationState
        // 2026-08-04 二次修正(build 70),推翻当天早些时候的"永远不会变成 .active"结论:
        // 那个结论来自在 arm 时刻**采样** applicationState 全是 1,而不是观察通知。build 69
        // 加上 `didBecomeActive` 打点后,真机三次冷启动都稳定在 **+429/+434ms** 变成 .active。
        //
        // 放宽到 .inactive 的代价很实在:起录成功(约 +350ms)时 App 还差 76ms 才 active,
        // 这一次 `startPictureInPicture` 必被 AVKit 以 -1001 拒绝,而这次失败会逼 AVKit 丢掉
        // 已预热的 controller 重建;重建后的那次要 2.4 秒才 active,甚至 11 秒超时失败
        // (13:07 与 13:09 两次实测)。反之,在 App 确实 .active 时请求,实测 166–571ms 就 active。
        //
        // 所以这里要求真正的 .active。够不到就交给 250ms 重试循环和 `didBecomeActive` 事件,
        // 两者都在冷启动 0.5 秒内命中,不会拖慢正常路径。
        guard state == .active else {
            // 逐条记录会瞬间冲掉轨迹里真正有用的历史,这里只记第一条。
            if !loggedBackgroundSkip {
                loggedBackgroundSkip = true
                Self.recordTrace("自动开启等待前台活跃:state=\(state.rawValue) reason=\(reason)(不在 .active 时请求必被 -1001 拒绝)")
            }
            return false
        }
        // 冷启动键盘路径下 arm 与起录并行推进(见 startIfIdle)。`isStarting` 期间同样
        // 绝不能让 activateStandby 走 `recorder.teardown()`——那会当场掐断正在建立的会话。
        let recording = phase == .recording || isStarting
        guard StandbyController.shared.requestStartFromUserAction() else {
            Self.recordTrace("自动开启待重试:画中画未就绪 state=\(state.rawValue) recording=\(recording) reason=\(reason)")
            return false
        }
        Self.recordTrace("请求建立待命 reason=\(reason) state=\(state.rawValue) recording=\(recording)")
        Task { await activateStandby(duringRecording: recording, allowInactiveForeground: true) }
        return true
    }

    /// 待命生命周期轨迹。`recordDiagnostic` 那种单槽 key 会被后一条覆盖——2026-08-04 排查
    /// "待命自动开启后 23 秒内消失"时,`stop()` 写的"待命已结束"就被随后的 didEnterBackground
    /// 覆盖掉了,导致完全看不到拆除原因。这里保留最近 40 条,足够还原一次完整会话。
    static func recordTrace(_ message: String) {
        let line = "\(Date().timeIntervalSince1970)|\(message)"
        var trace = AppGroup.suite?.stringArray(forKey: "diagTrace") ?? []
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 40) }
        AppGroup.suite?.set(trace, forKey: "diagTrace")
        DiagLog.log("standby", message)
    }

    /// 画中画在待命期间掉线的统一处理。
    ///
    /// 2026-08-04:自动开启的待命会在录音结束后很快消失。录音结束时 `recorder.stop()` 会
    /// 停用 AVAudioSession,而待命是"录音进行中"建起来的,这次停用有可能把挂在同一会话上的
    /// hosted video-call 画中画一并带走——这是自动开启路径独有的时序,手动从设置开关开启时
    /// 不会发生(那时录音引擎本来就是拆掉的)。
    /// 因此掉线不再直接判死:只要 App 还在前台(画中画只能在前台重建),就地重建一次;
    /// 重建不了才真正关闭待命。
    private func handleStandbyPictureInPictureLoss(reason: String) {
        guard !MeetingRecordingController.shared.isActive else {
            // 此时 PiP 已由会议起录路径拆除。只清掉运行时标记，不能以“恢复”名义
            // 触发新的 AVAudioSession 配置。
            standbyArmRetryTask?.cancel()
            standbyArmRetryTask = nil
            standbyEnabled = false
            standbyEndsAt = nil
            Self.recordTrace("会议录音中忽略 PiP 掉线恢复 reason=\(reason)")
            return
        }
        guard standbyEnabled, !standbyIsStarting else { return }
        // 同样只排除真正的 .background:重建也可能发生在键盘冷启动的 .inactive 过渡态前台。
        let appState = UIApplication.shared.applicationState
        guard appState != .background else {
            Self.recordTrace("画中画掉线且 App 在后台,关闭待命 reason=\(reason)")
            deactivateStandby(status: "画中画已被系统结束", teardownWhenIdle: false)
            return
        }
        guard standbyRebuildAttempts < 2 else {
            Self.recordTrace("画中画掉线,重建已达上限,关闭待命 reason=\(reason)")
            deactivateStandby(status: "画中画已被系统结束", teardownWhenIdle: false)
            return
        }
        standbyRebuildAttempts += 1
        guard StandbyController.shared.requestStartFromUserAction() else {
            Self.recordTrace("画中画掉线,重建请求被拒(possible=false) reason=\(reason)")
            deactivateStandby(status: "画中画已被系统结束", teardownWhenIdle: false)
            return
        }
        Self.recordTrace("画中画掉线,前台就地重建第 \(standbyRebuildAttempts) 次 reason=\(reason)")
        standbyEnabled = false      // 让 activateStandby 走完整启动路径
        Task { await activateStandby(allowInactiveForeground: true) }
    }

    private func restoreStandbyPresentationIfNeeded() {
        guard standbyEnabled else { return }
        // 待命只剩画中画一种:录完只需确认画中画会话还在,不再有暖会话分支和灵动岛卡片。
        guard StandbyController.shared.isActive
                || StandbyController.shared.isRecoveringUnexpectedSystemStop else {
            handleStandbyPictureInPictureLoss(reason: "录音结束后检查")
            return
        }
    }

    /// 使用 thinking 重新解析 ASR 原文，并整体替换这次录音所产生的待办组。
    func refineTodo(_ item: TodoItem) async throws {
        // 新待办优先用 ASR 原文；旧待办没有来源字段时，至少可以当前文字做精细重建。
        let source = (item.sourceRawText ?? item.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = IntentRouter.todoFormattingPrompt(dictionary: settings.dictionaryWords)
        let llm = CleanupService(baseURL: settings.activeLLMBaseURL,
                                 apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
        let refined = try await llm.clean(raw: source, systemPrompt: prompt, thinking: .enabled)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refined.isEmpty else { throw NSError(domain: "Todo", code: 2, userInfo: [NSLocalizedDescriptionKey: "重新识别未返回文字"]) }
        let lines = IntentRouter.parseTodoLines(refined)
        guard !lines.isEmpty else { throw NSError(domain: "Todo", code: 3, userInfo: [NSLocalizedDescriptionKey: "重新整理未生成待办事项"]) }
        let spokenAt = item.sourceRecordID
            .flatMap { sourceID in history.records.first(where: { $0.id == sourceID })?.date }
            ?? item.createdAt
        let plans = lines.map { TodoDateResolver.resolve($0, spokenAt: spokenAt) }
        let normalizedLines = zip(lines, plans).map { text, plan in plan?.normalizedText ?? text }
        guard let replacement = todos.replaceRecordingGroup(containing: item, with: normalizedLines) else {
            throw NSError(domain: "Todo", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法更新这组待办事项"])
        }
        enqueueCalendarUpdates(
            todos: replacement.items,
            plans: plans,
            obsoleteEventIdentifiers: replacement.obsoleteCalendarEventIdentifiers
        )
    }

    /// 手动编辑待办：相对日期按编辑发生时换算；若该待办已有日历事件，哪怕新文字
    /// 不再包含日期，也会更新事件标题并保留原来的日程时间。
    func updateTodoText(_ id: UUID, text: String) {
        let plan = TodoDateResolver.resolve(text, spokenAt: Date())
        let normalized = plan?.normalizedText ?? text
        guard let updated = todos.updateText(id, text: normalized) else { return }
        enqueueCalendarUpdates(todos: [updated], plans: [plan])
    }

    /// 待办文本先入库，日历权限/写入随后串行处理；日历服务绝不能拖住录音结束。
    private func enqueueCalendarUpdates(
        todos scheduledTodos: [TodoItem],
        plans: [TodoCalendarPlan?],
        obsoleteEventIdentifiers: [String] = []
    ) {
        guard plans.contains(where: { $0 != nil })
                || scheduledTodos.contains(where: { $0.calendarEventIdentifier != nil })
                || !obsoleteEventIdentifiers.isEmpty else { return }
        Task { @MainActor [weak self] in
            if !obsoleteEventIdentifiers.isEmpty {
                await TodoCalendarScheduler.shared.remove(eventIdentifiers: obsoleteEventIdentifiers)
            }
            for (todo, plan) in zip(scheduledTodos, plans) {
                guard plan != nil || todo.calendarEventIdentifier != nil,
                      let identifier = await TodoCalendarScheduler.shared.upsert(todo: todo, plan: plan) else { continue }
                self?.todos.setCalendarEventIdentifier(identifier, for: todo.id)
            }
        }
    }

    /// 云端整段识别;云端也失败时退到端侧稿。
    ///
    /// 这是端侧的**离线兜底**用途:改造前云端两条路径全失败等于这段口述作废(音频还在,
    /// 但用户拿不到文字)。端侧稿质量低于云端(2026-08-14 实测字符差异率约 11.9%),
    /// 因此要把来源标记进记录,让用户在历史页看到并可一键用云端重识别。
    /// 端侧同样拿不到结果时,维持原行为抛出云端的错误——错误信息对用户更有意义。
    private func cloudBatchOrOnDevice(wav: Data,
                                      source: inout RecognitionSource) async throws -> String {
        do {
            return try await batchASR(wav: wav)
        } catch {
            guard let fallback = await onDeviceFallback(wav: wav), !fallback.isEmpty else { throw error }
            DiagLog.log("asr", "云端识别失败，改用端侧兜底: \(Self.diagnosticDescription(error as NSError))")
            source = .onDevice
            return fallback
        }
    }

    /// 云端彻底失败时才现起的端侧整段转写。分歧检测、虚线标注和停录时的
    /// 投机整理均已下线，不再为了主听写提前运行一份端侧整段转写。
    private func onDeviceFallback(wav: Data) async -> String? {
        guard #available(iOS 26.0, *), OnDeviceTranscriber.isSupported,
              await OnDeviceTranscriber.isReady else { return nil }
        return try? await OnDeviceTranscriber().transcribe(wav: wav)
    }

    private func batchASR(wav: Data) async throws -> String {
        try await settings.prepareRelaySession()
        let usesWorker = settings.usesWorkerRelay
        let url = usesWorker ? settings.workerRelayASRURL : URL(string: settings.volcWsURLString)
        let appID = usesWorker ? "" : settings.volcAppId
        let accessToken = usesWorker ? "" : settings.volcAccessToken
        let bearerToken = usesWorker ? settings.activeWorkerToken : nil
        guard let url,
              usesWorker ? !settings.activeWorkerToken.isEmpty : (!appID.isEmpty && !accessToken.isEmpty) else {
            throw NSError(domain: "ASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先在设置里配置豆包识别服务"])
        }
        let corrections = DictionarySyncCoordinator.effectiveCorrections(
            records: history.records, manual: settings.manualCorrections,
            blocked: settings.blockedCorrectionSources)
        return try await VolcEngineASR(wsURL: url, appId: appID,
                                       accessToken: accessToken,
                                       resourceId: settings.volcResourceId,
                                       hotwordsContext: settings.hotwordsContext(corrections: corrections,
                                                                                 recentRecords: history.records),
                                       outputChineseVariant: settings.outputChineseVariant,
                                       protocolKind: usesWorker ? .nostream : .infer,
                                       bearerToken: bearerToken)
            .transcribe(wav: wav)
    }

    /// 把离线兜底记录改用云端重新识别并重新整理。
    ///
    /// 端侧兜底稿质量低于云端,原音一直留着,重识别成本只是一次网络往返。
    /// 失败保持原记录不动,只把 `lastCloudSyncStatus` 换成错误提示。
    func recognizeWithCloudAgain(record: DictationRecord) async {
        guard recloudingRecordID == nil else { return }
        guard let audioURL = history.audioURL(forRecordID: record.id),
              let wav = try? Data(contentsOf: audioURL) else {
            lastCloudSyncStatus = "原音已不在本机，无法重新识别"
            return
        }
        recloudingRecordID = record.id
        defer { recloudingRecordID = nil }
        do {
            let raw = try await batchASR(wav: wav)
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastCloudSyncStatus = "云端没有识别到内容"
                return
            }
            // WAV 头 44B,16kHz/Int16 单声道每秒 32,000B。路由口径与录音时一致。
            let duration = max(0, Double(wav.count - 44) / 32_000.0)
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
                                     apiKey: settings.activeLLMKey, model: settings.activeLLMModel)
            let clean = (try? await llm.clean(raw: raw, systemPrompt: prompt,
                                              forbidsNewNumbers: cleanupRoute == .homophoneOnly)) ?? raw
            let finalClean = ManualCorrections.apply(to: clean.isEmpty ? raw : clean, pairs: corrections)
            history.replaceRecognition(id: record.id, rawText: raw, cleanText: finalClean)
            refreshAutoDictionary()
            if settings.iCloudSyncEnabled,
               let updated = history.records.first(where: { $0.id == record.id }) {
                Task.detached(priority: .utility) { CloudHistorySync.push(updated) }
            }
            lastCloudSyncStatus = "已用云端重新识别"
        } catch {
            lastCloudSyncStatus = "云端重新识别失败：\(Self.diagnosticDescription(error as NSError))"
        }
    }

    func refreshAutoDictionary() {
        let auto = DictionaryMiner.mine(records: history.records,
                                        manual: Set(settings.manualDictionaryWords),
                                        blocked: settings.blockedDictionaryWords)
        settings.autoDictionaryRaw = auto.joined(separator: "\n")
        publishDictionaryToKeyboard()
        scheduleDictionarySync(reason: "自动词典/纠错对刷新") // 覆盖"挖掘出新纠错对后"这一触发点
    }

    /// 用户的显式编辑是最高置信纠错信号：落库、立即刷新词典/纠错对，
    /// 并在开启 iCloud 时异步推送，不阻塞主线程 UI。
    func updateHistoryFinalText(id: UUID, finalText: String) {
        history.updateFinalText(id: id, finalText: finalText)
        refreshAutoDictionary()
        guard settings.iCloudSyncEnabled,
              let record = history.records.first(where: { $0.id == id }) else { return }
        Task.detached(priority: .utility) { CloudHistorySync.push(record) }
    }

    /// 把生效词表(手动+自动,去屏蔽)镜像进 App Group,供拼音键盘同源注入。
    func publishDictionaryToKeyboard() {
        SharedDictionaryStore.publish(settings.dictionaryWords)
    }
}
