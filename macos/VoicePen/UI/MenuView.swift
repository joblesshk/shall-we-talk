import SwiftUI

/// 菜单栏下拉面板(设计包 §Screens.2):canvas 底、圆角 12、内边距 14、区块间距 12。
/// 「基准」入口已移入设置-模型服务页(见 SettingsView.apiTab 底部),底部收为四入口。
struct MenuView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            recordButton

            Toggle("识别后自动插入光标处", isOn: $appState.autoInsert)
                .toggleStyle(.checkbox)
                .tint(Theme.accent)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            if case .error(let msg) = appState.status {
                errorBanner(msg)
            } else if !appState.lastCleanText.isEmpty {
                ResultCard()
            }

            footer
        }
        .padding(16)
        .frame(width: 336)
        .background(Theme.bg)
    }

    // MARK: - 头部:声痕 glyph + 名称 + 状态

    private var header: some View {
        HStack(spacing: 10) {
            VoiceBarsGlyph(diameter: 22)
                .frame(width: 34, height: 34)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Shall We Talk")
                    .font(.system(size: 14, weight: .semibold))
                Text("语音输入与整理")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            statusLine
        }
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            switch appState.status {
            case .idle:
                Circle().fill(Theme.ok).frame(width: 6, height: 6)
                Text("就绪 · \(appState.settings.hotkeyDescription)")
            case .recording:
                StaticWaveformTicks(count: 3, color: Theme.danger, tickWidth: 2, spacing: 2,
                                    heights: [6, 10, 7])
                RecordingDot(diameter: 6)
                Text("录音中")
            case .processing:
                ProgressView().controlSize(.mini).tint(Theme.processing)
                Text("整理中…")
            case .error:
                Circle().fill(Theme.warn).frame(width: 6, height: 6)
                Text("出错")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - 主录音卡：与 iOS 的 Quiet Ink 录音键保持同一三态语言。

    private var recordButton: some View {
        let state: QuietInkRecordCardState = switch appState.status {
        case .recording: .recording
        case .processing: .processing
        case .idle, .error: .idle
        }
        return Button(action: { appState.toggle() }) {
            QuietInkRecordCard(state: state, audioLevel: appState.audioLevel,
                                hotkey: appState.settings.hotkeyDescription)
        }
        .buttonStyle(.pressable)
        .animation(Motion.standard, value: state)
    }

    // MARK: - 错误横幅:细描边,不填充

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warn)
            Text(msg).font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(4)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msg, forType: .string)
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                .buttonStyle(.plain)
                .help("复制错误详情")
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warn.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - 底部入口:细线分隔,悬停 ink@5% 高亮

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            HStack(spacing: 0) {
                FooterAction(
                    title: appState.todos.pendingCount > 0 ? "待办 \(appState.todos.pendingCount)" : "待办",
                    systemImage: "checklist", tint: Theme.accent
                ) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "todos")
                }
                FooterAction(title: "历史", systemImage: "clock.arrow.circlepath", tint: Theme.accent) {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "history")
                }
                FooterAction(title: "设置", systemImage: "gearshape", tint: Theme.textSecondary) {
                    showSettings()
                }
                FooterAction(title: "退出", systemImage: "power", tint: Theme.danger) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// LSUIElement(菜单栏 App)未激活时 openSettings 会静默失败:先激活再打开,并确保窗口到前台
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.frameAutosaveName.contains("Settings") || $0.title.contains("设置") || $0.title.contains("Settings") || $0.title.contains("General") || $0.title.contains("通用") }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// 底部入口:图标 + 文字,等宽 grid,悬停 ink@5% 高亮 r8
struct FooterAction: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .hoverHighlight(opacity: 0.05, radius: 8)
    }
}

/// 最近一次结果卡片:card 底 + r10 + 0.5pt separator 描边
struct ResultCard: View {
    @EnvironmentObject var appState: AppState
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(showRaw ? "ASR 原文" : "整理稿")
                    .quietSectionLabel()
                Spacer()
                Button(showRaw ? "看整理稿" : "看原文") { showRaw.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                Button {
                    let text = showRaw ? appState.lastRawText : appState.lastCleanText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                    .buttonStyle(.plain)
                    .help("复制")
            }
            ScrollView {
                Text(showRaw ? appState.lastRawText : appState.lastCleanText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 100)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }
}
