import AppIntents
import Foundation
import UIKit

/// 操作按钮 / 快捷指令与主 App 之间的最小请求桥。
/// App Intent 可能先于 SwiftUI 视图创建而执行，因此先落一个带时间戳的请求，
/// DictationController 初始化 / 进入 active 时再幂等消费。
enum ActionCaptureRequestStore {
    private static let key = "actionCaptureRequestedAt"
    private static let forceTodoKey = "actionCaptureRequestForceTodo"

    /// - Parameter forceTodo: 发起方是否要求本次捕捉一律建待办(语音待办/操作按钮),
    ///   还是照常按触发词路由(语音输入捷径)。与时间戳同批落盘,谁先 consume 谁生效。
    static func request(forceTodo: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        UserDefaults.standard.set(forceTodo, forKey: forceTodoKey)
    }

    /// 只消费最近请求，避免 App 被杀后数小时再打开时突然开始录音。
    static func consume(maxAge: TimeInterval = 30) -> (date: Date, forceTodo: Bool)? {
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return nil }
        let forceTodo = UserDefaults.standard.bool(forKey: forceTodoKey)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: forceTodoKey)
        let date = Date(timeIntervalSince1970: raw)
        guard Date().timeIntervalSince(date) <= maxAge else { return nil }
        return (date, forceTodo)
    }
}

/// Action 录音的跨进程状态。AppIntent 可能不和正在录音的 SwiftUI App 运行在同一执行上下文，
/// 因此第二次按键不能只读取某个 DictationController 实例的 phase。
enum ActionCaptureSessionStore {
    private static let key = "actionCaptureSessionV1"

    private struct State: Codable {
        var isRecording = false
        var recordingStartedAt: TimeInterval = 0
        var stopRequestedAt: TimeInterval = 0
    }

    private static var suite: UserDefaults? { AppGroup.suite }

    private static func load() -> State {
        guard let data = suite?.data(forKey: key),
              let value = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return value
    }

    private static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        suite?.set(data, forKey: key)
    }

    static var isRecording: Bool {
        let state = load()
        // 崩溃遗留状态不能让未来的 Action 按键永远被解释成停止。窗口原为 4 小时,实测太长:
        // 一次后台捕捉被系统回收后,操作按钮整整 4 小时只会发停止请求,重开 App 也救不回来
        // (2026-08-06)。真实口述不会超过这个量级,进程存活期间本就靠内存态判断,不依赖此窗口。
        return state.isRecording && Date().timeIntervalSince1970 - state.recordingStartedAt < 10 * 60
    }

    static func markRecording() {
        save(State(isRecording: true,
                   recordingStartedAt: Date().timeIntervalSince1970,
                   stopRequestedAt: 0))
    }

    static func requestStop() {
        var state = load()
        state.stopRequestedAt = Date().timeIntervalSince1970
        save(state)
    }

    static func consumeStopRequest(maxAge: TimeInterval = 15) -> Bool {
        var state = load()
        let requestedAt = state.stopRequestedAt
        guard requestedAt > 0 else { return false }
        state.stopRequestedAt = 0
        save(state)
        return Date().timeIntervalSince1970 - requestedAt <= maxAge
    }

    static func clear() {
        save(State())
    }
}

/// 系统可直接挂到 iPhone 操作按钮。
/// iOS 18+ 通过 AudioRecordingIntent 取得录音所需的后台执行资格；
/// Live Activity 在录音全程显示状态，因此无需再把完整 App 界面切到前台。
/// 保留旧类型名以避免用户已经配置好的 Action Button 失效；对外名称已改为「语音待办」。
struct StartTodoCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "语音待办"
    static let description = IntentDescription("开始语音识别；使用 Shall We Talk 键盘时自动插入，同时复制到剪贴板并保存记录；一律同时加入待办。只想记录不想建待办时改用「语音输入」捷径。")
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    func perform() async throws -> some IntentResult {
        // **无条件入口打点**。2026-08-07 的日志里,第二次按操作按钮时 start / stop 两个分支的
        // 日志一条都没有 —— 那说明 `perform()` 根本没被系统调用,而不是走错了分支。但当时只有
        // 分支内部有打点,无法把"系统压根没调"和"调了但提前 return"区分开。这一行专治这个。
        // 实时状态优先于跨进程标记。标记会被 VAD 自动停清掉,而用户往往正是在"说完停顿了
        // 一下、VAD 刚停"的那一两秒里按下停止键;只看标记就会把这一按判成"开始新一段"
        // (2026-08-07 真机日志三次全是这个模式)。
        let live = await DictationController.shared.actionCaptureLiveState
        DiagLog.log("actionIntent",
                    "perform 进入 录音中=\(live.recording) 识别整理中=\(live.processing) "
                    + "跨进程标记=\(ActionCaptureSessionStore.isRecording)")

        // 上一段还在识别整理:此时起新一段必然拿不到样本(start 的状态守卫会挡),
        // 只会白白触发前台重试把 App 顶出来。直接忽略这一按,比"假装开始"诚实。
        if live.processing {
            DiagLog.log("actionIntent", "上一段仍在识别整理中,忽略本次按键")
            return .result()
        }

        // 第二次 Action 按键走独立的跨进程停止通道，不再与“开始请求”抢同一个时间戳。
        // 正在录音的 App 会被 Darwin 即时唤醒；0.5 秒状态心跳还会轮询该请求作为兜底。
        if live.recording || ActionCaptureSessionStore.isRecording {
            // 这条分支此前一行日志都不写。2026-08-06 排查时,遗留标记让每一次按键都静默走到这里,
            // 现场表现为"按了没反应、日志里什么都没有",白白多花一轮真机复现。
            DiagLog.log("actionIntent", "按键判定为停止(检测到进行中的捕捉)")
            ActionCaptureSessionStore.requestStop()
            DarwinBridge.post(DarwinBridge.cmdCaptureStop)
            return .result()
        }

        // iOS 26.5 上，第三方 App 在完全冷却的后台进程中新激活 AVAudioSession
        // 会被系统拒绝；AudioRecordingIntent 并不代替这一层麦克风隐私限制。
        // 已有暖会话时仍在后台近乎即时恢复；冷会话则动态切到前台再开麦，
        // 避免用户只看到笼统的“录音失败”。
        // **不再预判性地把 App 顶到前台**(2026-08-07 用户要求:App 不该被唤醒,灵动岛才是
        // 该亮的那个)。原来的逻辑是"冷态就断定后台开不了麦,先 continueInForeground",
        // 而 §12.20 已经建了一套**事后**兜底:后台起录若拿不到样本才切前台重试。两者重复,
        // 且前者每次都把 App 拉到前台 —— 而 App 在前台时 iOS 不会把它自己的 Live Activity
        // 呈现到灵动岛上,于是操作按钮这条路的灵动岛从来没亮过。
        //
        // 现在一律先在后台试:`begin()` 先建卡片(这是 AudioRecordingIntent 后台开麦的凭证),
        // 再起录;真拿不到样本时下面的 `!started` 分支才退回前台重试,行为与改前等价,
        // 只是把"预判"换成了"实测"。
        let canResumeInBackground = await DictationController.shared.canResumeActionCaptureInBackground
        var canRetryInForeground = false
        if #available(iOS 26.0, *) {
            canRetryInForeground = systemContext.currentMode.canContinueInForeground
            DiagLog.log("actionIntent",
                        "按键判定为开始 mode=\(systemContext.currentMode) "
                        + "可后台恢复=\(canResumeInBackground) 可退前台重试=\(canRetryInForeground)")
        } else {
            DiagLog.log("actionIntent", "按键判定为开始 可后台恢复=\(canResumeInBackground)")
        }
        ActionCaptureRequestStore.request(forceTodo: true)
        DarwinBridge.post(DarwinBridge.cmdCapture)
        // AppIntent 与 App 共用同一进程时直接接单，省去 0.5 秒轮询；
        // 时间戳请求仍保留，覆盖系统冷启动时 SwiftUI 对象稍后创建的情况。
        let started = await DictationController.shared.consumeActionCaptureRequestAndWait(
            canRetryInForeground: canRetryInForeground)

        // 后台起录拿不到样本时唯一的出路是切到前台重来一次;不重试就会录了个空,
        // 还把跨进程状态留成"正在录音"(§12.20)。这条现在是**唯一**会把 App 顶到前台的
        // 路径 —— 只有实测失败才走,不再预判。
        if !started, canRetryInForeground, #available(iOS 26.0, *) {
            DiagLog.log("actionIntent", "后台起录零样本,切到前台重试一次")
            try await continueInForeground(nil, alwaysConfirm: false)
            ActionCaptureRequestStore.request(forceTodo: true)
            await DictationController.shared.consumeActionCaptureRequestAndWait()
        }
        return .result()
    }
}

@available(iOS 18.0, *)
extension StartTodoCaptureIntent: AudioRecordingIntent {}

@available(iOS 17.0, *)
extension StartTodoCaptureIntent: LiveActivityIntent {}

/// 「语音输入」捷径:与 `StartTodoCaptureIntent` 共用同一套跨进程状态机(录音/停止/
/// Live Activity/剪贴板/键盘插入全部一致),唯一区别是发起请求时 `forceTodo=false`——
/// 是否额外建待办仍照旧按 `IntentRouter` 触发词路由,不强制。用于绑定「轻点背面」/
/// 辅助功能自定义操作等场景,与 Action Key 上的「语音待办」强制待办入口并存、互不影响。
struct StartNoteCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "语音输入"
    static let description = IntentDescription("后台开始或停止录音，不自动打开主界面。开始时返回空文本，停止后返回识别文字；在快捷指令中接上“如果有值→拷贝到剪贴板”，即可使用其他输入法粘贴。")
    static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let live = await DictationController.shared.actionCaptureLiveState
        if live.recording || live.processing {
            let text = try await DictationController.shared.stopActionCaptureReturningText()
            return .result(value: text)
        }
        if ActionCaptureSessionStore.isRecording {
            ActionCaptureSessionStore.requestStop()
            DarwinBridge.post(DarwinBridge.cmdCaptureStop)
            throw NSError(domain: "ShortcutCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "已请求停止录音，但当前无法取得结果；请稍后在记录中查看。"])
        }
        ActionCaptureRequestStore.request(forceTodo: false)
        DarwinBridge.post(DarwinBridge.cmdCapture)
        let started = await DictationController.shared.consumeActionCaptureRequestAndWait()
        guard started else {
            throw NSError(domain: "ShortcutCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "后台录音未能启动，请手动打开 Shall We Talk 检查麦克风权限和待命状态后重试。"])
        }
        return .result(value: "")
    }
}

@available(iOS 18.0, *)
extension StartNoteCaptureIntent: AudioRecordingIntent {}

@available(iOS 17.0, *)
extension StartNoteCaptureIntent: LiveActivityIntent {}

/// Keep the identifier so previously installed meeting shortcuts gain toggle behavior.
struct OpenMeetingRecordsIntent: AppIntent {
    static let title: LocalizedStringResource = "开始或停止会议录音"
    static let description = IntentDescription("第一次运行打开会议页面并开始会议录音，再次运行停止当前会议录音并保存整理。")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "openMeetingRecordsRequestedAt")
        for _ in 0..<30 {
            if UIApplication.shared.applicationState == .active { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard UIApplication.shared.applicationState == .active else {
            throw NSError(domain: "MeetingShortcut", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "请解锁手机并打开 Shall We Talk 后重试。"])
        }
        let message = try await MeetingRecordingController.shared.toggleFromShortcut()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct VoicePenAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMeetingRecordsIntent(),
            phrases: ["用 \(.applicationName) 开始或停止会议录音"],
            shortTitle: "会议录音",
            systemImageName: "person.wave.2"
        )
        AppShortcut(
            intent: StartTodoCaptureIntent(),
            phrases: [
                "用 \(.applicationName) 语音待办",
                "用 \(.applicationName) 录音待办",
            ],
            shortTitle: "语音待办",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StartNoteCaptureIntent(),
            phrases: [
                "用 \(.applicationName) 语音输入",
                "用 \(.applicationName) 开始语音识别",
                "用 \(.applicationName) 语音记一笔",
            ],
            shortTitle: "语音输入",
            systemImageName: "note.text"
        )
    }
}
