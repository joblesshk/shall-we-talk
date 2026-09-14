import ActivityKit
import Foundation
import UIKit

@MainActor
final class CaptureLiveActivityController {
    static let shared = CaptureLiveActivityController()

    private var activity: Activity<CaptureActivityAttributes>?
    private var startedAt = Date()

    private init() {}

    /// 系统「实时活动」总开关。关着时 `Activity.request` 根本不会被调用,而且**不抛错**——
    /// 2026-08-06 就是因为这里静默返回,现场表现只有"灵动岛不显示",日志里一个字都没有,
    /// 白白花了两轮去改渲染和自愈(那些改动都在这道门后面,压根没机会执行)。
    /// 后果不止是没提示:`AudioRecordingIntent` 能后台开麦的前提就是全程有 Live Activity
    /// (见 §11.1a),关着时操作按钮的后台录音可能连麦克风都拿不到。
    static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 只在状态发生变化时记一条,避免 0.5 秒心跳把日志刷满。
    private var lastLoggedAuthorization: Bool?

    private func logAuthorizationIfChanged(_ enabled: Bool, at site: String) {
        guard lastLoggedAuthorization != enabled else { return }
        lastLoggedAuthorization = enabled
        DiagLog.log("liveActivity", "系统实时活动开关=\(enabled ? "开" : "关") site=\(site)")
    }

    private var lastLoggedActivityState: ActivityState?

    /// 卡片的存活状态。这是区分两类故障的**决定性**一条:`.active` 说明卡片活着、
    /// 问题在渲染或系统呈现优先级;`.ended` / `.dismissed` 说明它被悄悄杀掉了,
    /// 那就要去找谁杀的。同样只在状态变化时记一条,避免 0.5 秒心跳刷屏。
    private func logActivityStateIfChanged(_ state: ActivityState, at site: String) {
        guard lastLoggedActivityState != state else { return }
        lastLoggedActivityState = state
        DiagLog.log("liveActivity", "卡片状态=\(state) site=\(site)")
    }

    /// 供心跳调用:把当前卡片的存活状态落进日志(仅变化时)。
    func logCurrentActivityState(at site: String) {
        guard let activity else {
            logActivityStateIfChanged(.dismissed, at: "\(site)/无卡片")
            return
        }
        logActivityStateIfChanged(activity.activityState, at: site)
    }

    func begin() async {
        let enabled = Self.areActivitiesEnabled
        logAuthorizationIfChanged(enabled, at: "begin")
        guard enabled else { return }
        startedAt = Date()

        // 只清掉异常退出遗留的 Action 捕捉卡片；免切换待命有独立生命周期。
        // **必须 await**:原来是 fire-and-forget,紧接着就请求新卡片,旧的还没死就多了一张。
        // 多张实时活动并存时灵动岛不给常驻紧凑态(2026-08-08 实测症状)。
        let stale = Activity<CaptureActivityAttributes>.activities
            .filter { $0.attributes.source == "actionButton" }
        if !stale.isEmpty {
            DiagLog.log("liveActivity", "清理遗留卡片 \(stale.count) 张")
            for activity in stale {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        let state = CaptureActivityAttributes.ContentState(
            stage: .starting,
            message: "正在启动语音转写…",
            startedAt: startedAt
        )
        // appState 是这里最关键的一个字段。后台启动 Live Activity 是受限的:只有 App 因
        // `LiveActivityIntent` 而运行的那段窗口内才被允许。`StartTodoCaptureIntent` 确实
        // 遵循了 LiveActivityIntent,但 `perform()` 里同时发了 Darwin `cmdCapture`,
        // 那条通道会在**未被 perform() await 的游离 Task** 里调到这里——一旦是它先接单,
        // begin() 就跑在特权窗口之外,request 会被系统拒绝。日志里 appState=2(background)
        // 配上紧随其后的"启动失败",即可坐实这条竞态(2026-08-06 排查中)。
        let appState = UIApplication.shared.applicationState.rawValue
        do {
            activity = try Activity.request(
                attributes: CaptureActivityAttributes(source: "actionButton"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            DiagLog.log("liveActivity",
                        "卡片已创建 appState=\(appState) "
                        + "在场活动数=\(Activity<CaptureActivityAttributes>.activities.count)")
        } catch {
            DiagLog.log("liveActivity",
                        "启动失败 appState=\(appState): \(Self.describe(error))")
        }
    }

    /// `localizedDescription` 对 `ActivityAuthorizationError` 常常只给一句泛泛的话,
    /// 排查时需要看到具体 case(`.unsupported` / `.denied` / `.globalMaximumExceeded` …)。
    private static func describe(_ error: Error) -> String {
        if let authError = error as? ActivityAuthorizationError {
            return "\(authError) | \(authError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    /// 录音全程确保灵动岛上有一张"正在录音"的卡片,掉了就原地重建。
    ///
    /// 起因(2026-08-06 用户反馈):按操作按钮起录后灵动岛很快就什么都不显示了,分不清
    /// 到底还在不在录。卡片消失的路径不止一条(系统回收、`Activity.request` 当时就失败、
    /// 进程被杀后重启但录音由暖会话续着),逐条堵不如让目标状态自愈——由 0.5 秒心跳
    /// 低频调用,`startedAt` 沿用本次录音的起点,重建后计时器接着走而不是从零开始。
    func ensureRecording(startedAt recordingStartedAt: Date, message: String) {
        let enabled = Self.areActivitiesEnabled
        logAuthorizationIfChanged(enabled, at: "ensureRecording")
        guard enabled else { return }
        let state = CaptureActivityAttributes.ContentState(
            stage: .recording, message: message, startedAt: recordingStartedAt
        )
        // ⚠️ 只判 `activity != nil` 是不够的:系统把卡片结束/驳回之后,我们手上这个引用
        // **依然非 nil**,只是 `activityState` 变成 .ended / .dismissed。build 105 的自愈
        // 就漏了这一层,于是"卡片被悄悄杀掉"这条路径永远走不到重建分支,自愈形同虚设
        // (2026-08-07 排查中发现)。必须看状态,不能看引用。
        if let activity, activity.activityState == .active {
            // 已在录音态且计时起点没变就不重复推送:ActivityKit 的更新不是免费的。
            if activity.content.state == state { return }
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        if let dead = activity {
            logActivityStateIfChanged(dead.activityState, at: "ensureRecording")
            self.activity = nil
        }
        startedAt = recordingStartedAt
        do {
            activity = try Activity.request(
                attributes: CaptureActivityAttributes(source: "actionButton"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            DiagLog.log("liveActivity", "录音中卡片缺失,已重建")
        } catch {
            DiagLog.log("liveActivity", "录音中重建失败: \(error.localizedDescription)")
        }
    }

    /// 起录**确认真的收到音频之后**发一次带提示的更新。
    ///
    /// 为什么用 AlertConfiguration 而不是指望灵动岛常驻态:待命开着时 PiP 占着
    /// 灵动岛的常驻槽位(2026-09-02 模拟器实测:无 PiP 时灵动岛显示完全正常,
    /// 所以占槽位是唯一原因)。但 §11.1g 记过一条系统行为 —— 常驻紧凑态被压住时
    /// **提示动画仍然照出**。提示这条通道不与 PiP 争用,也不依赖 App 在前台,
    /// 因此是"待命开着时让用户知道已经开始录"的唯一现成手段。
    ///
    /// 触感反馈走不通:`UIFeedbackGenerator` 只在前台有效;录音期间音频会话是
    /// 无输出节点的 `.record`,也放不出提示音。
    func announceRecording(message: String) {
        guard let activity else { return }
        let state = CaptureActivityAttributes.ContentState(
            stage: .recording,
            message: message,
            startedAt: startedAt
        )
        let alert = AlertConfiguration(
            title: "正在录音",
            body: LocalizedStringResource(stringLiteral: message),
            sound: .default
        )
        DiagLog.log("liveActivity", "起录提示已发出")
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil),
                alertConfiguration: alert
            )
        }
    }

    func update(stage: CaptureActivityAttributes.Stage, message: String) {
        guard let activity else { return }
        let state = CaptureActivityAttributes.ContentState(
            stage: stage,
            message: message,
            startedAt: startedAt
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// 静默结束:不弹提示、不留终态卡片。用于"这次失败但马上会重试"的场景 ——
    /// 先报一次「录音未完成」再成功,比不报更让人困惑。
    func endSilently() {
        guard let activity else { return }
        DiagLog.log("liveActivity", "卡片被本 App 静默结束(将重试)")
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    func complete(message: String) {
        finish(stage: .completed, message: message, alertTitle: "语音已处理")
    }

    func fail(message: String) {
        finish(stage: .failed, message: message, alertTitle: "录音未完成")
    }

    private func finish(
        stage: CaptureActivityAttributes.Stage,
        message: String,
        alertTitle: LocalizedStringResource
    ) {
        guard let activity else { return }
        let state = CaptureActivityAttributes.ContentState(
            stage: stage,
            message: message,
            startedAt: startedAt
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(8))
        let alert = AlertConfiguration(title: alertTitle, body: LocalizedStringResource(stringLiteral: message), sound: .default)
        // 区分"我们主动结束"与"系统把它收走了":后者在日志里只会表现为卡片状态突然变
        // ended/dismissed,没有这一行。2026-08-08 排查卡片录音中途消失时全靠这个区分。
        DiagLog.log("liveActivity", "卡片被本 App 结束 stage=\(stage)")
        self.activity = nil
        Task {
            await activity.update(content, alertConfiguration: alert)
            // ⚠️ 绝不能用「睡 5 秒再 end」:App 在这 5 秒里被挂起,end() 就永远不会执行,
            // 卡片以 active 状态泄漏在系统里。build 114 让 App 全程留在后台之后这成了常态,
            // 泄漏的卡片越攒越多 —— 多张实时活动并存时 iOS 的呈现方式会变:提示动画照出,
            // 常驻紧凑态不给,这正是 2026-08-08 的症状。
            // `.after` 把延时交给系统:end 立刻登记,之后 App 死活都不影响。
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
        }
    }
}

/// 键盘免切换待命使用独立 Live Activity；它与一次性的 Action Button 语音输入
/// 生命周期不同，不能在一次识别完成后随 Capture 卡片一起结束。
@MainActor
final class StandbyLiveActivityController {
    static let shared = StandbyLiveActivityController()

    private var activity: Activity<CaptureActivityAttributes>?
    private var startedAt = Date()

    private init() {
        activity = Activity<CaptureActivityAttributes>.activities.first {
            $0.attributes.source == "standby"
        }
    }

    func begin(expiresAt: Date?, message: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        startedAt = Date()

        for stale in Activity<CaptureActivityAttributes>.activities
            where stale.attributes.source == "standby" {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        let state = CaptureActivityAttributes.ContentState(
            stage: .standby,
            message: message,
            startedAt: startedAt,
            expiresAt: expiresAt
        )
        do {
            activity = try Activity.request(
                attributes: CaptureActivityAttributes(source: "standby"),
                content: ActivityContent(state: state, staleDate: expiresAt),
                pushType: nil
            )
        } catch {
            DiagLog.log("standby", "灵动岛待命启动失败: \(error.localizedDescription)")
        }
    }

    func showStandby(expiresAt: Date?, message: String) {
        update(stage: .standby, message: message, expiresAt: expiresAt)
    }

    func showRecording() {
        update(stage: .recording, message: "麦克风正在采样；点录音键即可结束", expiresAt: nil)
    }

    func showProcessing(message: String = "正在识别并整理文字…") {
        update(stage: .processing, message: message, expiresAt: nil)
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func update(stage: CaptureActivityAttributes.Stage, message: String, expiresAt: Date?) {
        guard let activity else { return }
        let state = CaptureActivityAttributes.ContentState(
            stage: stage,
            message: message,
            startedAt: stage == .recording ? Date() : startedAt,
            expiresAt: expiresAt
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: expiresAt))
        }
    }
}
