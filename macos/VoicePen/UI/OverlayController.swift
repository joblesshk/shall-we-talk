import AppKit
import SwiftUI
import Combine

/// 录音悬浮 HUD(设计包 §Screens.3,对应 iOS 录音坞;差异②——独立浮窗、悬浮于任意 App 之上)。
/// nonactivating 浮窗,不抢焦点、不打断当前输入;整体背景可拖拽,位置持久记忆(默认首次
/// 出现在屏幕顶部居中)。仅做视觉/窗口行为改造:录音/整理/上屏这条业务链路完全不变,
/// 只是 show()/hide() 的调用时机(在 AppState 里)与之前一致。
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    /// 面板固定画布尺寸:足够容纳最宽的「完成态」(w400)+ 左侧拖拽把手余量,内容在画布内
    /// 顶部居中对齐,状态切换只改变可见卡片大小,不改变窗口本身尺寸——避免拖拽记忆的位置
    /// 因为窗口 resize 而跳动。
    private static let canvasSize = NSSize(width: 460, height: 210)
    private static let positionDefaultsKey = "overlayHUDOrigin"

    init(appState: AppState) {
        let hosting = NSHostingView(rootView: OverlayView().environmentObject(appState))
        hosting.frame = NSRect(origin: .zero, size: Self.canvasSize)
        panel = NSPanel(contentRect: hosting.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // 阴影由 SwiftUI 画(floatingShadow)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true // 整体背景可拖拽(设计包新增,差异②)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init()
        panel.delegate = self
    }

    func show() {
        if let saved = Self.savedOrigin(), let visible = Self.clampedOrigin(saved, size: panel.frame.size) {
            panel.setFrameOrigin(visible)
        } else {
            positionTopCenter()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height))
    }

    /// 拖拽结束(松开鼠标)后持久化位置;下次 show() 复用,直到用户再次拖拽。
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin),
                                      forKey: Self.positionDefaultsKey)
        }
    }

    private static func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: positionDefaultsKey) else { return nil }
        return NSPointFromString(s)
    }

    /// 显示器断开、缩放或排列变化后，把旧坐标夹回当前可见区域。若旧窗口与所有
    /// 当前屏幕均无交集，返回 nil，由调用方回到主屏默认位置。
    private static func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint? {
        let candidate = NSRect(origin: origin, size: size)
        let matches = NSScreen.screens.map { screen in
            (screen, candidate.intersection(screen.visibleFrame).width
                * candidate.intersection(screen.visibleFrame).height)
        }
        guard let best = matches.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        let visible = best.0.visibleFrame
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(origin.x, visible.minX), maxX),
                       y: min(max(origin.y, visible.minY), maxY))
    }
}

/// 整体背景拖拽区:铺在内容最底层,任何未被按钮/文本选择等交互控件占用的像素点击即拖窗口。
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 左侧常驻拖拽把手:2×3 圆点,ink@28%,仅装饰(真正拖拽靠 WindowDragArea 覆盖整个背景)。
private struct DragHandleGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(Theme.textPrimary.opacity(0.28))
        .accessibilityHidden(true)
    }
}

struct OverlayView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var recordingStart: Date?
    @State private var elapsed: TimeInterval = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            HStack(alignment: .center, spacing: 10) {
                DragHandleGrip()
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 0 : 14)
            .frame(width: cardWidth, height: isCompact ? 44 : nil, alignment: .leading)
            .dockMaterial(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(errorStroke)
            .floatingShadow()
            .onHover { appState.overlayHoverChanged($0) } // 悬停暂停自动退出
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard, value: cardWidth)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.standard, value: corner)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .background(WindowDragArea())
        .onChange(of: appState.status) { _, newStatus in
            if newStatus == .recording {
                if recordingStart == nil { recordingStart = Date() }
            } else {
                recordingStart = nil
                elapsed = 0
            }
        }
        .onReceive(ticker) { _ in
            if let start = recordingStart { elapsed = Date().timeIntervalSince(start) }
        }
    }

    // MARK: - 状态 → 尺寸/圆角(设计包 §Screens.3 定稿值)

    private var cardWidth: CGFloat {
        switch appState.status {
        case .recording: return 360
        case .processing: return 300
        case .error, .idle: return 400
        }
    }
    private var corner: CGFloat {
        switch appState.status {
        case .recording: return Radius.dockExpanded      // 26
        case .processing: return Radius.dockIdlePill      // 22(单行胶囊化)
        default: return Radius.card                        // 18(完成态/错误态)
        }
    }
    private var isCompact: Bool { appState.status == .processing }

    @ViewBuilder
    private var errorStroke: some View {
        if case .error = appState.status {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.4), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.status {
        case .recording: recordingContent
        case .processing: processingContent
        case .error(let msg): errorContent(msg)
        case .idle: doneContent
        }
    }

    // MARK: - 展开录音态:实时波形 + 状态行(红点/计时/热键/停止键)+ 实时转写

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                LiveWaveformTicks(level: appState.audioLevel)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                RecordingDot(diameter: 8, showsGlow: true)
                Text("正在聆听 · 识别中")
                    .quietHeadline()
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                Text(elapsedString)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                hotkeyChip
                stopButton
            }
        }
    }

    private var elapsedString: String {
        let total = max(0, Int(elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var hotkeyChip: some View {
        Text(appState.settings.hotkeyDescription)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.separator, lineWidth: 0.5))
    }

    /// 36pt recordingRed 圆停止键,内 12pt 白色 r3.5 方块
    private var stopButton: some View {
        Button { appState.toggle() } label: {
            ZStack {
                Circle().fill(Theme.danger).frame(width: 36, height: 36)
                RoundedRectangle(cornerRadius: Radius.stopKeyInner, style: .continuous)
                    .fill(.white)
                    .frame(width: 12, height: 12)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("停止")
    }

    // MARK: - 整理中:单行胶囊化(进度环 + 文案 + 尾部实时文本)

    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.processing)
            Text(appState.streamingFellBack ? "正在整理成文…(流式中断,本次整段识别)" : "正在整理成文…")
                .quietHeadline()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if !appState.liveText.isEmpty {
                Text(appState.liveText)
                    .quietFootnote()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 错误态:同完成态版式,warn 三角图标(红色不用于错误)

    private func errorContent(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.warn)
            Text(msg)
                .quietBody()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 完成态:ok 勾 + 插入说明与耗时 + 关闭;手动复制模式追加复制条

    private var doneContent: some View {
        Group {
            if !appState.lastCleanText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ok)
                        Text(appState.insertionNote)
                            .quietFootnote()
                        Spacer()
                        Button {
                            appState.dismissOverlay()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("关闭")
                    }
                    Text(appState.lastCleanText)
                        .font(.system(size: 13)).lineSpacing(3)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if appState.manualCopyMode {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.lastCleanText, forType: .string)
                            appState.dismissOverlay()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.doc.fill")
                                Text("复制全文").fontWeight(.semibold)
                                Spacer()
                                Text("复制后 ⌘V 粘贴到任意位置")
                                    .font(.system(size: 11)).opacity(0.8)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Capsule().fill(Theme.accent))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }
}
