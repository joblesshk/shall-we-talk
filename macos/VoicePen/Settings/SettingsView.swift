import SwiftUI
import AppKit
import ShallWeTalkCore

/// 设置窗口分页(设计包 §Screens.6):顶部图标 tab 条自绘(选中 = accent@12% tile r8 +
/// accent glyph/文字,未选中 inkSecondary)。固定 560×480,不随分页改变窗口尺寸——
/// 弃用系统原生 TabView(会按分页内容自动 resize、tab 项外观也不可自定义到这个精度)。
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用", api = "连接设置", cleanup = "整理偏好", dict = "词典", privacy = "隐私与同步"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "keyboard"
        case .api: return "network"
        case .cleanup: return "text.badge.checkmark"
        case .dict: return "character.book.closed"
        case .privacy: return "lock.icloud"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var diagResult = ""
    @State private var selectedTab: SettingsTab = .general

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "版本 \(version)（Build \(build)）"
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            Group {
                switch selectedTab {
                case .general: generalTab
                case .api: apiTab
                case .cleanup: cleanupTab
                case .dict: dictTab
                case .privacy: privacyTab
                }
            }
        }
        .frame(width: 560, height: 480)
        .background(Theme.bg)
        .tint(Theme.accent)
        .quietWindowChrome()
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: .medium))
                        Text(tab.rawValue).font(.system(size: 10.5))
                    }
                    .foregroundStyle(selectedTab == tab ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? Theme.accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    /// 分区头:行首图标 tile(28pt r8 accent@10% + accent glyph)+ Section Label,卡外。
    private func sectionHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            RowIconTile(systemName: icon, size: 22)
            Text(title).quietSectionLabel()
        }
    }

    /// 同步状态行(设计包新增:Footnote + 右侧 accent 文字按钮),隐私与同步页 / 词典同步行共用。
    private func syncStatusRow<Actions: View>(_ status: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Text(status).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Spacer()
            actions()
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("外观", selection: appState.settings.$appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { m in Text(m.rawValue).tag(m.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appState.settings.appearanceModeRaw) { _, _ in
                    appState.applyAppearance()
                }
            } header: { sectionHeader("circle.lefthalf.filled", "外观") }
            Section {
                HotkeyRecorderField()
                Text("可使用单独的修饰键(⌘⌥⌃⇧)、带修饰键的组合，或 F1–F12 单键。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            } header: { sectionHeader("keyboard", "全局快捷键(开始/结束录音)") }
            Section {
                Toggle("停顿后自动结束录音", isOn: appState.settings.$vadEnabled)
                if appState.settings.vadEnabled {
                    Picker("静音阈值", selection: appState.settings.$vadSilenceSeconds) {
                        Text("1.5 秒").tag(1.5)
                        Text("2.5 秒(推荐)").tag(2.5)
                        Text("4 秒").tag(4.0)
                    }
                    .pickerStyle(.segmented)
                }
                Text("开口说话后,持续静音达到阈值即自动结束并上屏;随时也可手动按快捷键结束。思考停顿较多时建议选 4 秒。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            } header: { sectionHeader("waveform", "自动停止(VAD)") }
            Section {
                Text(versionDescription)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            } header: { sectionHeader("info.circle", "关于 Shall We Talk") }
        }
        .formStyle(.grouped)
    }

    /// 精简统计入口:完整的卡片式增删改界面已升级为独立窗口(DictionaryWindowView)——
    /// 设置窗口固定 560×480,装不下"宽敞卡片网格"的定稿要求,与 History/待办/CompareLab/
    /// BatchBench 同构("按钮从设置跳出独立窗口"是本项目已有的 macOS 惯例)。
    private var dictTab: some View {
        Form {
            Section {
                HStack(spacing: 24) {
                    dictStat(label: "个人词典", count: appState.settings.manualDictionaryWords.count)
                    dictStat(label: "自动学习", count: appState.settings.autoDictionaryWords.count)
                    Spacer()
                }
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dictionary")
                } label: {
                    Text("打开词典管理…").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.quietSolid)
                Text("人名、行业术语、产品名等易被识别错的词。双通道生效:含英文的中英混词优先作为识别热词,全部词条注入整理环节强制采用词典写法;反复出现的词与反复做过的同一修正也会自动学习加入。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            } header: { sectionHeader("character.book.closed", "词典") }
        }
        .formStyle(.grouped)
    }

    private func dictStat(label: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var apiTab: some View {
        Form {
            Section {
                Picker("连接线路", selection: appState.settings.$networkRouteRaw) {
                    ForEach(RelayNetworkRoute.allCases) { route in
                        Text(route.title).tag(route.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.status == .recording || appState.status == .processing)
                Text("选择适合当前网络的连接方式。录音或处理过程中不能切换线路。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if !diagResult.isEmpty {
                    Text(diagResult).font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                if appState.settings.usesWorkerRelay {
                    Text("首次使用自动完成连接授权，无需登录或输入激活码。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            } header: { sectionHeader("network", "连接设置") }
        }
        .formStyle(.grouped)
        .task(id: appState.settings.networkRouteRaw) {
            guard appState.settings.usesWorkerRelay else { diagResult = ""; return }
            diagResult = "正在检查连接…"
            let selected = appState.settings.networkRoute
            do {
                try await appState.settings.prepareRelaySession()
                guard !Task.isCancelled, selected == appState.settings.networkRoute else { return }
                var request = URLRequest(url: selected.warmupURL!)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 8
                request.setValue("Bearer " + appState.settings.activeWorkerToken, forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, selected == appState.settings.networkRoute else { return }
                diagResult = (response as? HTTPURLResponse)?.statusCode == 204
                    ? "连接与授权正常" : "当前线路不可用，请选择其他连接方式。"
            } catch {
                guard !Task.isCancelled, selected == appState.settings.networkRoute else { return }
                diagResult = error.localizedDescription
            }
        }
    }

    private var cleanupTab: some View {
        Form {
            Section {
                Picker("整理力度", selection: appState.settings.$cleanupLevelRaw) {
                    ForEach(CleanupLevel.allCases) { l in Text(l.rawValue).tag(l.rawValue) }
                }
                .pickerStyle(.segmented)
                Stepper(
                    "完整整理阈值：\(Int(appState.settings.fullCleanupThresholdSeconds)) 秒",
                    value: appState.settings.$fullCleanupThresholdSeconds,
                    in: DictationPolicy.fullCleanupThresholdRange,
                    step: 1
                )
                Text("轻档始终使用短口述整理，不分段编号；重档才按录音时长与列举信号选择短口述或完整整理。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Picker("输出字体", selection: appState.settings.$outputTraditionalChinese) {
                    Text("简体").tag(false)
                    Text("繁体(香港)").tag(true)
                }
                .pickerStyle(.segmented)
                Text("开启后使用香港繁体写法；关闭时使用简体。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            } header: { sectionHeader("text.badge.checkmark", "整理力度") }

            Section {
                Toggle("跳过无需整理的短句（试用）", isOn: appState.settings.$redundantCleanupGateEnabled)
                TextEditor(text: appState.settings.$customPrompt)
                    .frame(height: 120)
                    .font(.callout)
                Text("例:数字一律用阿拉伯数字;保留「其实/但是」这类开头词。基础整理规则不受影响。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text("已输入 \(appState.settings.customPrompt.count) 字；仅前 500 字用于整理。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Button("恢复默认(清空)") { appState.settings.customPrompt = "" }
                    .buttonStyle(.quietStroke)
            } header: { sectionHeader("pencil.line", "自定义指令(L3,最多 500 字)") }

            Section {
                AppProfileEditor(settings: appState.settings)
            } header: { sectionHeader("app.badge.checkmark", "按 App 档位(Power Mode)") }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Section {
                Toggle("跨设备同步口述历史(仅文本)", isOn: appState.settings.$iCloudSyncEnabled)
                    .onChange(of: appState.settings.iCloudSyncEnabled) { _, enabled in
                        if enabled { appState.syncHistoryFromCloud() }
                    }
                if appState.settings.iCloudSyncEnabled {
                    syncStatusRow(appState.lastHistorySyncStatus) {
                        Button("立即同步") { appState.syncHistoryFromCloud() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .disabled(appState.isHistorySyncing)
                        Button("全量上传") { appState.pushAllHistoryToCloud() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .disabled(appState.isHistorySyncing)
                    }
                }
                Text("同步内容为识别原文与整理稿等文字,录音音频始终只存本机。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Divider()
                Toggle("跨设备同步个人词典与纠错对", isOn: appState.settings.$dictionarySyncEnabled)
                    .onChange(of: appState.settings.dictionarySyncEnabled) { _, enabled in
                        if enabled { appState.scheduleDictionarySync(reason: "开启同步") } else { appState.cancelDictionarySync() }
                    }
                Text(appState.lastDictionarySyncStatus)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text("与 macOS 上确认的加词/修改在 iOS(含键盘)同样生效,反之亦然;删除会同步为墓碑,不会被旧设备重新加回。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            } header: { sectionHeader("arrow.triangle.2.circlepath.icloud", "iCloud 同步") }
            Section {
                Toggle("保留录音音频(用于未来的发音分析)", isOn: appState.settings.$keepAudio)
                Text("音频与文字仅存储在本机。")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Button {
                    appState.clearHistory()
                } label: {
                    Text("清空全部历史与音频")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            } header: { sectionHeader("lock", "本机隐私") }
        }
        .formStyle(.grouped)
    }
}

/// 快捷键录制控件:点"更改"后按下新组合即保存;Esc 取消
struct HotkeyRecorderField: View {
    @EnvironmentObject var appState: AppState
    @State private var capturing = false
    @State private var pendingModifierKeyCode: Int?
    @State private var pendingModifier: NSEvent.ModifierFlags = []

    var body: some View {
        HStack {
            Text(appState.settings.hotkeyDescription)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
            Button(capturing ? "请按下新快捷键…(⎋ 取消)" : "更改") {
                capturing ? stopCapture() : startCapture()
            }
        }
        // 不能仅靠 addLocalMonitor：SwiftUI 的设置窗口未必把按键交给该监听器，
        // 而 ⌘ 组合会先走菜单命令。这个零尺寸 AppKit view 是实际 first responder。
        .background(HotkeyCaptureResponder(
            isCapturing: capturing,
            onKeyDown: handleKeyDown,
            onFlagsChanged: handleFlagsChanged
        ))
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        pendingModifierKeyCode = nil
        pendingModifier = []
        capturing = true
        HotkeyCaptureState.isCapturing = true
    }

    private func handleKeyDown(_ e: NSEvent) {
        guard capturing else { return }
        // 若随后按了普通键，应录为组合快捷键而非此前按下的单独修饰键。
        pendingModifierKeyCode = nil
        pendingModifier = []
        if e.keyCode == 53 { // Esc 取消
            stopCapture()
            return
        }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // 必须带修饰键,或是 F 功能键,避免把普通输入误存成全局快捷键。
        guard !mods.isEmpty || HotkeyManager.isFunctionKey(Int(e.keyCode)) else {
            NSSound.beep()
            return
        }
        appState.settings.hotkeyKeyCode = Int(e.keyCode)
        appState.settings.hotkeyModifiersRaw = Int(mods.rawValue)
        stopCapture()
    }

    private func handleFlagsChanged(_ e: NSEvent) {
        guard capturing,
              let modifier = HotkeyManager.standaloneModifier(forKeyCode: Int(e.keyCode)) else { return }

        let activeModifiers = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if activeModifiers.contains(modifier) {
            // 先等待松开：这样按住 ⌥ 再按 Space 仍会录为 ⌥Space。
            pendingModifierKeyCode = Int(e.keyCode)
            pendingModifier = modifier
        } else if pendingModifierKeyCode == Int(e.keyCode) {
            appState.settings.hotkeyKeyCode = Int(e.keyCode)
            appState.settings.hotkeyModifiersRaw = Int(pendingModifier.rawValue)
            stopCapture()
        }
    }

    private func stopCapture() {
        pendingModifierKeyCode = nil
        pendingModifier = []
        capturing = false
        HotkeyCaptureState.isCapturing = false
    }
}

/// 设置页快捷键录制的真实键盘焦点。`performKeyEquivalent` 专门接住 ⌘ 组合，避免它被
/// Settings 的菜单命令优先消费；普通键则由 `keyDown` 接收。仅在录制态吞掉事件。
private struct HotkeyCaptureResponder: NSViewRepresentable {
    let isCapturing: Bool
    let onKeyDown: (NSEvent) -> Void
    let onFlagsChanged: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.isCapturing = isCapturing
        view.onKeyDown = onKeyDown
        view.onFlagsChanged = onFlagsChanged
        guard isCapturing else { return }
        DispatchQueue.main.async {
            guard view.isCapturing, let window = view.window else { return }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
        }
    }

    final class CaptureView: NSView {
        var isCapturing = false
        var onKeyDown: ((NSEvent) -> Void)?
        var onFlagsChanged: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isCapturing else { super.keyDown(with: event); return }
            onKeyDown?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isCapturing else { return super.performKeyEquivalent(with: event) }
            onKeyDown?(event)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            guard isCapturing else { super.flagsChanged(with: event); return }
            onFlagsChanged?(event)
        }
    }
}
