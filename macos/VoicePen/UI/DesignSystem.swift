import SwiftUI
import AppKit
import Combine

// MARK: - 设计系统 · 动效令牌(macOS)
//
// 与 iOS `App/DesignSystem.swift` 同一美学概念「静墨 / Quiet Ink」:暖中性画布 + 单一沉静蓝强调,
// 大量留白,情绪是「从容而笃定」——一个口述工具应当安静、即时、不抢戏。桌面端在此基础上按
// README 的「新增规则」补了 hover/pressed/focus、toolbar/inset 卡片圆角等 macOS 控件惯例。
//
// 动效原则(苹果《Designing Fluid Interfaces》,译到 SwiftUI,与 iOS 完全一致):
//  - 用弹簧,不用固定时长;默认临界阻尼(dampingFraction=1.0,无过冲),
//    只有动量手势才留一点回弹(0.8)。
//  - 动画由 state 驱动,天然可打断;减弱动态效果时用交叉淡入替代弹簧/位移。
//  - 新增(桌面输入惯例):hover 用 ease-out 0.12s 即时响应,而非弹簧。
enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)  // 默认 UI 状态变化
    static let snappy   = Animation.spring(response: 0.26, dampingFraction: 1.0)  // 小控件即时反馈
    static let gentle   = Animation.spring(response: 0.5,  dampingFraction: 1.0)  // 大表面/内容进出
    static let bouncy   = Animation.spring(response: 0.35, dampingFraction: 0.8)  // 仅动量手势用回弹
    static let hover    = Animation.easeOut(duration: 0.12)                       // 新增:hover 即时响应
}

// MARK: - 间距 / 圆角刻度
enum Space {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 36

    // 新增(桌面控件惯例):窗口内容边距、卡片内边距、侧栏行内边距
    static let windowMarginSM: CGFloat = 16
    static let windowMarginLG: CGFloat = 24
    static let cardPaddingSM: CGFloat = 14
    static let cardPaddingLG: CGFloat = 16
    static let sidebarRowH: CGFloat = 9
    static let sidebarRowV: CGFloat = 10
}
enum Radius {
    /// 与 iOS 27 的内容卡片一致；连续曲率让桌面窗口保持轻盈但不过度拟物。
    static let card: CGFloat = 22            // 卡片(历史详情编辑卡、待办卡)
    static let chip: CGFloat = 12
    static let dockExpanded: CGFloat = 26    // HUD 展开态
    static let dockIdlePill: CGFloat = 22    // HUD 待机胶囊 = 高度/2(h44)
    static let iconTile: CGFloat = 8         // 设置图标 tile
    static let stopKeyInner: CGFloat = 3.5   // 停止键内方块

    // 新增(差异③:macOS 控件惯例)
    static let insetGroupCard: CGFloat = 12  // 设置分组卡
    static let sidebarRow: CGFloat = 10      // 历史侧栏行卡
    static let toolbarTile: CGFloat = 7      // toolbar 按钮 tile
    static let menuPanel: CGFloat = 12       // 菜单栏下拉面板
}

// MARK: - 字体层级(桌面密度档:iOS 六级字阶整体下调一档;新增 Window Title)
// 层次靠字重 + 字号 + 行距,不靠颜色。计时数字用 .monospacedDigit() 单独在调用处加。
extension View {
    /// Large Title(仅空态/引导页使用):26/32 Bold,tracking −2%
    func quietLargeTitle() -> some View {
        font(.system(size: 26, weight: .bold)).tracking(-0.52)
    }
    /// Title 2(弹层标题):17/22 Semibold
    func quietTitle2() -> some View {
        font(.system(size: 17, weight: .semibold))
    }
    /// Headline(HUD 状态文案「正在聆听 · 识别中」):15/20 Semibold
    func quietHeadline() -> some View {
        font(.system(size: 15, weight: .semibold))
    }
    /// Body(备忘正文、待办项、设置行标题):14pt,行距刻意放宽(≈22)
    func quietBody() -> some View {
        font(.system(size: 14, weight: .regular)).lineSpacing(6)
    }
    /// Footnote(时长、提示、同步状态行):12/16 Regular,inkSecondary
    func quietFootnote() -> some View {
        font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.textSecondary)
    }
    /// Section Label(日期分组头、设置分区头):11/14 Semibold,tracking +5%,uppercase,inkTertiary(同 iOS)
    func quietSectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold))
            .tracking(0.55)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
    }
    /// Window Title(新增:标题栏标题):13 Semibold ink
    func quietWindowTitle() -> some View {
        font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }
    /// Window Subtitle(新增:标题栏同步副行):10.5 inkSecondary
    func quietWindowSubtitle() -> some View {
        font(.system(size: 10.5, weight: .regular)).foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - 静态波形刻度(装饰性;HUD 待机胶囊左侧、按钮内图形。圆头、统一语言)
struct StaticWaveformTicks: View {
    var count: Int = 4
    var color: Color = Theme.textTertiary
    var tickWidth: CGFloat = 2.5
    var spacing: CGFloat = 3
    var heights: [CGFloat] = [10, 16, 12, 7]
    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(color).frame(width: tickWidth, height: heights[i % heights.count])
            }
        }
    }
}

/// iOS App Icon 同源的五段声波标记。它用于品牌位和主入口；菜单栏模板图标仍保留其
/// macOS 专属的状态表达，避免在 18pt 下丢失录音/整理反馈。
struct VoiceBarsGlyph: View {
    var diameter: CGFloat = 20
    var color: Color = .white

    private let proportions: [CGFloat] = [0.42, 0.72, 1.0, 0.62, 0.46]

    var body: some View {
        HStack(alignment: .center, spacing: diameter * 0.12) {
            ForEach(Array(proportions.enumerated()), id: \.offset) { _, proportion in
                Capsule()
                    .fill(color)
                    .frame(width: max(2, diameter * 0.105), height: diameter * proportion)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 将 iOS 的“静墨”录音卡适配到 macOS 菜单栏面板：保留三态色面、声波与整理骨架，
/// 但使用鼠标友好的整卡点击目标，不复制移动端底部坞的布局。
enum QuietInkRecordCardState: Equatable { case idle, recording, processing }

struct QuietInkRecordCard: View {
    let state: QuietInkRecordCardState
    var audioLevel: Float = 0
    var hotkey: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardColor: Color {
        switch state {
        case .idle: return Color(light: 0xF2EFE9, dark: 0x272521)
        case .recording: return Color(light: 0xDFE9F4, dark: 0x203040)
        case .processing: return Color(light: 0xEFECE6, dark: 0x292725)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardColor)
            if state == .processing { processingFill }
            content.padding(.horizontal, 18).padding(.vertical, 15)
        }
        .frame(height: 98)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(state == .recording ? Theme.accent.opacity(0.65) : Theme.separator,
                              lineWidth: state == .recording ? 1.25 : 0.5)
        }
        .shadow(color: state == .recording ? Theme.accent.opacity(0.14) : .clear,
                radius: 0, x: 0, y: 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : Motion.standard, value: state)
    }

    private var processingFill: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0.24)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.64)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            HStack(spacing: 16) {
                VoiceBarsGlyph(diameter: 46, color: Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("点一下开始口述").font(.system(size: 15, weight: .semibold))
                    Text("语音会按当前整理规则直接写入光标处")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                keyHint
            }
        case .recording:
            VStack(spacing: 9) {
                LiveWaveformTicks(level: audioLevel, tickCount: 15, maxHeight: 30)
                HStack(spacing: 7) {
                    RecordingDot(diameter: 7, showsGlow: true)
                    Text("正在聆听 · 再点一下结束")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    keyHint
                }
            }
        case .processing:
            HStack(spacing: 16) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.textPrimary.opacity(0.16)).frame(width: 142, height: 7)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.textPrimary.opacity(0.10)).frame(width: 96, height: 7)
                    Text("正在整理文字…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var keyHint: some View {
        Text(hotkey)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - 实时滚动波形(HUD 展开录音态;19 根 3pt 圆头刻度、间距 3、高 6–34)
//
// 数据源:AppState.audioLevel(0…1,已做 attack/release 包络),纯复用、不碰采集逻辑。
// 观感目标:稀疏、参差、多彩的独立刻度,不是连续条——
//  ① 每根固定宽度 + 间距,`.fixedSize()` 锁死总宽,绝不拉伸填满容器;
//  ② 采样 sqrt 提对比 + 每根独立参差(包络太平滑会连成一条);
//  ③ 逐根按自身高度着色:低 → accent 半透明,中 → accent 实色,峰 → textPrimary(近白/墨)。
// accessibilityReduceMotion:退化为静态参差刻度(不滚动不跳动,着色规则相同)。
struct LiveWaveformTicks: View {
    var level: Float
    var tickCount: Int = 19
    var tickWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 6
    var maxHeight: CGFloat = 34

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Float] = []
    private let sampler = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private static let staticPattern: [Float] = [0.1, 0.3, 0.18, 0.5, 0.75, 0.42, 0.85, 1.0, 0.62,
                                                 0.92, 0.5, 0.68, 0.35, 0.58, 0.22, 0.45, 0.12, 0.3, 0.06]

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<tickCount, id: \.self) { i in
                let v = sample(at: i)
                Capsule()
                    .fill(tickColor(v))
                    .frame(width: tickWidth, height: tickHeight(v))
            }
        }
        .fixedSize()
        .frame(height: maxHeight)
        .onReceive(sampler) { _ in
            guard !reduceMotion else { return }
            let shaped = (min(1, max(0, level))).squareRoot()
            let jittered = min(1, shaped * Float.random(in: 0.5...1.35))
            var next = history
            if next.count >= tickCount { next.removeFirst(next.count - tickCount + 1) }
            next.append(jittered)
            history = next
        }
        .animation(.linear(duration: 0.05), value: history)
        .accessibilityHidden(true)
    }

    private func sample(at i: Int) -> Float {
        if reduceMotion { return Self.staticPattern[i % Self.staticPattern.count] }
        let offset = i - (tickCount - history.count)
        guard offset >= 0, offset < history.count else { return 0 }
        return history[offset]
    }

    private func tickHeight(_ v: Float) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(min(1, max(0, v)))
    }

    private func tickColor(_ v: Float) -> Color {
        let v = Double(min(1, max(0, v)))
        if v >= 0.8 { return Theme.textPrimary }
        if v >= 0.5 { return Theme.accent }
        return Theme.accent.opacity(0.35 + 0.8 * v)
    }
}

// MARK: - 兼容旧调用点的品牌标记
// 旧版是 8 刻度环；现在 App Icon 已与 iOS 统一为五段声波，空态也必须同步，避免一个
// 产品同时出现两套品牌符号。保留类型名以缩小这次纯视觉改动的影响面。
struct SoundTraceGlyph: View {
    var diameter: CGFloat = 17
    var color: Color = Theme.accent

    var body: some View {
        VoiceBarsGlyph(diameter: diameter, color: color)
    }
}

// MARK: - 「材质坞」背景(悬浮 HUD / 菜单栏面板共用底材质)
// .regularMaterial + 0.5pt 描边;减弱透明度退化实色。浮窗专用阴影档见 floatingShadow。
private struct DockMaterialModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background(reduceTransparency ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(.regularMaterial), in: shape)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
    }
}
extension View {
    func dockMaterial<S: InsettableShape>(_ shape: S) -> some View { modifier(DockMaterialModifier(shape: shape)) }

    /// 悬浮浮窗阴影档(新增,差异②:浮窗需与任意背景分离):
    /// 浅色 y10 blur34 ink@18%;深色不用卡片阴影,浮窗阴影加深至黑@45%。
    func floatingShadow() -> some View {
        modifier(FloatingShadowModifier())
    }
}
private struct FloatingShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 34, y: 10)
    }
}

// MARK: - 按压反馈按钮样式(触点即缩放,非松手才反馈;尊重「减弱动态效果」)
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.12)
                                    : .spring(response: 0.30, dampingFraction: 0.9),
                       value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - 描边 / 实色按钮样式(桌面控件惯例;历史详情操作行、设置内嵌按钮等共用:h26 r7)
struct QuietStrokeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.15), lineWidth: 0.5))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.7 : 1))
    }
}
struct QuietSolidButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.85 : 1))
    }
}
extension ButtonStyle where Self == QuietStrokeButtonStyle {
    static var quietStroke: QuietStrokeButtonStyle { QuietStrokeButtonStyle() }
}
extension ButtonStyle where Self == QuietSolidButtonStyle {
    static var quietSolid: QuietSolidButtonStyle { QuietSolidButtonStyle() }
}

// MARK: - hover 高亮(新增,差异③:鼠标输入惯例——所有可点元素必须有 hover 态)
// 行/入口铺 ink@3–5%,toolbar tile ink@5%,ease-out 0.12s 即时响应。
struct HoverHighlight: ViewModifier {
    var opacity: Double = 0.05
    var radius: CGFloat = 8
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(Theme.textPrimary.opacity(hovering ? opacity : 0),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}
extension View {
    func hoverHighlight(opacity: Double = 0.05, radius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(opacity: opacity, radius: radius))
    }
}

// MARK: - 卡片表面(自适应表面色 + 细描边 + 与内容分离的柔和阴影;同 iOS CardSurface)
struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.card
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 10, y: 4)
    }
}
extension View {
    func cardSurface(radius: CGFloat = Radius.card) -> some View { modifier(CardSurface(radius: radius)) }
}

// MARK: - inset 分组卡(新增,差异③:设置/侧栏惯例——card 底 + r12 + 0.5pt separator 描边,无阴影)
struct InsetGroupCard: ViewModifier {
    var radius: CGFloat = Radius.insetGroupCard
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
    }
}
extension View {
    func insetGroupCard(radius: CGFloat = Radius.insetGroupCard) -> some View { modifier(InsetGroupCard(radius: radius)) }
}

// MARK: - 行图标 tile(设置行首图标;28pt r8 accent@10% 底 + accent glyph,同 iOS 设置行语言)
struct RowIconTile: View {
    var systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.iconTile, style: .continuous))
    }
}

// MARK: - 正在录音的脉动红点(减弱动态效果时为静态实心点)
/// opacity 1→0.35,~1s ease-in-out 循环;可选外圈 4pt 光晕。
struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var diameter: CGFloat = 8
    var showsGlow: Bool = false
    var body: some View {
        ZStack {
            if showsGlow {
                Circle()
                    .fill(Theme.danger.opacity(0.18))
                    .frame(width: diameter + 8, height: diameter + 8)
                    .opacity(reduceMotion ? 0 : (on ? 1 : 0.4))
            }
            Circle()
                .fill(Theme.danger)
                .frame(width: diameter, height: diameter)
        }
        .opacity(reduceMotion ? 1 : (on ? 1 : 0.35))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { on = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 窗口标题栏融入内容(新增,差异①:多窗口范式——canvas 实色、透明融合,靠 0.5pt
// separator 分界,而非系统默认的材质标题栏)。用一个不可见的 NSViewRepresentable 拿到宿主
// NSWindow 后一次性配置外观,不涉及交互/内容,纯窗口 chrome。
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.bg)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
extension View {
    func quietWindowChrome() -> some View { background(WindowChromeConfigurator()) }
}

// MARK: - 「材质化」进出转场(从触发处生长;减弱动态效果时退化为交叉淡入)
extension AnyTransition {
    static var materialize: AnyTransition {
        .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
    }
}
