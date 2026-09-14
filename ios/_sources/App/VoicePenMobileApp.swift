import SwiftUI
import UIKit
import ShallWeTalkCore

@main
struct VoicePenMobileApp: App {
    @StateObject private var controller = DictationController.shared

    init() {
        Self.configureQuietInkAppearance()
        // ShallWeTalkCore 不依赖 App 的具体日志实现,启动时注入跨进程共享的 DiagLog。
        CoreDiagLog.handler = { component, message in DiagLog.log(component, message) }
    }

    /// iOS 26+（含 iOS 27）全面交给系统 Liquid Glass，只保留 SwiftUI tint。
    /// iOS 18–25 继续使用原 Quiet Ink appearance，避免老系统视觉回归。
    private static func configureQuietInkAppearance() {
        if #available(iOS 26.0, *) { return }

        let ink = QuietInkPalette.uiColor(.ink)
        let inkTertiary = ink.withAlphaComponent(0.37)
        let separatorColor = QuietInkPalette.uiColor(.separator)
        let accent = QuietInkPalette.uiColor(.accent)

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .kern: -0.68,
            .foregroundColor: ink,
        ]
        nav.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: ink,
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tab.shadowColor = separatorColor
        let item = UITabBarItemAppearance()
        item.normal.iconColor = inkTertiary
        item.normal.titleTextAttributes = [.foregroundColor: inkTertiary, .font: UIFont.systemFont(ofSize: 10)]
        item.selected.iconColor = accent
        item.selected.titleTextAttributes = [.foregroundColor: accent, .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    do { try await controller.settings.prepareRelaySession() }
                    catch {
                        let failure = error as NSError
                        DiagLog.log("relay", "启动预授权未完成 domain=\(failure.domain) code=\(failure.code)")
                    }
#if DEBUG
                    await controller.settings.runEnrolledRelayProbeIfRequested()
#endif
                }
                .environmentObject(controller)
                .environmentObject(MeetingRecordingController.shared)
                .tint(Theme.accent)
                .onOpenURL { url in
                    // voicepen://record  = 键盘拉起(输入意图)
                    // voicepen://edit    = 键盘冷启动修改上一段已交付文字
                    // voicepen://capture = 快捷指令/操作按钮拉起(通用语音输入,剪贴板+触发词分流)
                    // voicepen://meeting-stop = 会议 Live Activity 的停止控件
                    guard url.scheme == "voicepen" else { return }
                    let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    DiagLog.log("openURL", "收到 \(url.absoluteString) appState=\(UIApplication.shared.applicationState.rawValue)")
                    if target == "standby-stop" {
                        controller.setStandbyEnabled(false)
                        return
                    }
                    if target == "meeting-stop" {
                        MeetingRecordingController.shared.stop()
                        return
                    }
                    if let request = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "request" })?.value {
                        let snapshot = KeyboardBridgeStore.snapshot()
                        let age = Date().timeIntervalSince1970 - snapshot.requestSentAt
                        guard request == snapshot.requestID, age >= 0, age <= 5 else {
                            DiagLog.log("hostReturn", "拒绝过期或被替换的 URL 请求"); return
                        }
                    }
                    controller.mode = (target == "capture") ? .capture : .keyboard
                    // capture 走 URL 进来时也建状态卡。此前只有 App Intent 那条路调
                    // `begin()`,于是从快捷指令用 `voicepen://capture` 拉起的捕捉全程
                    // 没有 Live Activity —— 既没有状态显示,也拿不到 §12.20 那张
                    // "后台开麦凭证"。两条入口的行为应当一致(2026-09-02)。
                    if target == "capture" {
                        Task { await CaptureLiveActivityController.shared.begin() }
                    }
                    controller.startIfIdle()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var meetingController: MeetingRecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .record
    @AppStorage("openMeetingRecordsRequestedAt") private var meetingNavigationRequestedAt: Double = 0

    private func consumeMeetingNavigation() {
        guard meetingNavigationRequestedAt > 0 else { return }
        let age = Date().timeIntervalSince1970 - meetingNavigationRequestedAt
        meetingNavigationRequestedAt = 0
        guard age >= 0, age <= 30 else { return }
        tab = .meetings
    }
    // 外观:与 MobileSettingsStore 同 key。View 层 @AppStorage 观察 UserDefaults 变化,
    // 设置页 Picker 一改这里即时重渲染并施加 .preferredColorScheme(跟随系统 = nil)。
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    private enum Tab { case record, meetings, todos, settings }

    /// 录音是全局状态,但记录页的录音坞已给出完整指示;非记录页则由这个全局悬浮条兜底,
    /// 保证「无论在哪个 tab,录音进行中都恰好有一个清晰指示 + 停止控件」。会议录音有自己
    /// 的坞/Live Activity 指示(见 MeetingTab/MeetingLiveActivityController),不复用这条。
    private var showsGlobalOverlay: Bool {
        (controller.phase == .recording || controller.phase == .processing)
            && tab != .record && !meetingController.isActive
    }

    var body: some View {
        // 四个直白、具体的标签(信息架构:页1 记录=录音+备忘;历史已并入首页备忘流,不再单列;
        // 页2 会议=独立的长会话录音+转写+纪要,与「记录」的短口述场景分开)
        TabView(selection: $tab) {
            RecordView()
                .tag(Tab.record)
                .tabItem { Label("记录", systemImage: "waveform") }
            MeetingTab()
                .tag(Tab.meetings)
                .tabItem { Label("会议", systemImage: "person.wave.2") }
            TodosTab()
                .tag(Tab.todos)
                .tabItem { Label("待办", systemImage: "checklist") }
                .badge(controller.todos.pendingCount)
            SettingsTab()
                .tag(Tab.settings)
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(Theme.accent)
        .quietInkTabChrome()
        .overlay(alignment: .bottom) {
            if showsGlobalOverlay {
                // 胶囊主体点按 = 切回记录 tab(停止钮是内部独立 Button,点击不会冒泡到这里);
                // 用 environment 注入切换动作,GlobalRecordingBar() 本身保持零参调用不变。
                GlobalRecordingBar()
                    .environment(\.selectRecordTab, {
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard) { tab = .record }
                    })
                    .padding(.bottom, 58)   // 浮在系统 tab bar 之上
                    .transition(reduceMotion ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.gentle, value: showsGlobalOverlay)
        // sample-buffer PiP 的透明 source layer 常驻根窗口。它位于 TabView 背后，
        // 只负责让 AVKit 在用户开启待命时已有就绪的媒体源，不改变 App 视觉。
        .background(PictureInPictureStandbySourceView().allowsHitTesting(false))
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
        .onAppear {
            consumeMeetingNavigation()
            controller.consumeActionCaptureRequest()
            // 装机默认待命为开。这里是首次启动时最早能建立画中画的时机之一;真正生效
            // 通常在下面的 scenePhase == .active,两处都调是因为冷启动的先后顺序不固定,
            // armStandbyIfPreferred 本身幂等(已开/正在开/正在录音都会直接返回)。
            controller.armStandbyIfPreferred()
        }
        .onChange(of: meetingNavigationRequestedAt) { _, _ in
            consumeMeetingNavigation()
        }
        .onChange(of: controller.phase) { _, newPhase in
            if controller.mode == .capture && newPhase == .recording { tab = .record }
        }
        .onChange(of: controller.shortcutClipboardMessage) { _, message in
            if message != nil { tab = .record }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                consumeMeetingNavigation()
                controller.consumeActionCaptureRequest()
                controller.scheduleDictionarySync(reason: "回前台")
                controller.syncCredentials(reason: "回前台")
                // 会话到期/被来电中断/进程被回收之后,回到前台按偏好补建,
                // 不需要用户再拨一次开关。
                controller.armStandbyIfPreferred()
            }
            if newPhase == .background {
                // 切走的这一刻正是一次真机复现刚结束的时候,此时刷新镜像,
                // 远程拉到的就是刚跑完那一轮的完整日志。
                // 用户多半是刚在设置里改完凭证才切走,这一刻推送最及时。
                controller.syncCredentials(reason: "切后台")
                DiagLog.mirrorToAppContainer()
            }
        }
    }
}

private struct PictureInPictureStandbySourceView: UIViewRepresentable {
    final class SourceView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            StandbyController.shared.layoutSource(in: self)
        }
    }

    func makeUIView(context: Context) -> SourceView {
        let view = SourceView()
        view.backgroundColor = .clear
        view.isOpaque = false
        StandbyController.shared.attachSource(to: view)
        return view
    }

    func updateUIView(_ uiView: SourceView, context: Context) {
        StandbyController.shared.layoutSource(in: uiView)
    }

    static func dismantleUIView(_ uiView: SourceView, coordinator: Void) {
        StandbyController.shared.detachSource(from: uiView)
    }
}
