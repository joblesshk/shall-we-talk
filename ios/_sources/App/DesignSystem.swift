import AudioToolbox
import SwiftUI
import UIKit
import Combine

// MARK: - 设计系统 · 动效令牌
//
// 美学概念「静墨 / Quiet Ink」:暖中性画布 + 单一沉静蓝强调,大量留白,
// 想传达的情绪是「从容而笃定」(calm-confident)——一个口述工具应当安静、即时、不抢戏。
//
// 动效原则(苹果《Designing Fluid Interfaces》,译到 SwiftUI):
//  - 用弹簧,不用固定时长;默认临界阻尼(dampingFraction=1.0,无过冲),
//    只有动量手势(甩动/拖拽释放)才留一点回弹(0.8)。
//  - 动画由 state 驱动(withAnimation/.animation(value:)),天然可打断。
//  - 减弱动态效果时用交叉淡入替代弹簧/位移。
enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1.0)  // 默认 UI 状态变化
    static let snappy   = Animation.spring(response: 0.26, dampingFraction: 1.0)  // 小控件即时反馈
    static let gentle   = Animation.spring(response: 0.5,  dampingFraction: 1.0)  // 大表面/内容进出
    static let bouncy   = Animation.spring(response: 0.35, dampingFraction: 0.8)  // 仅动量手势用回弹
}

// MARK: - 间距 / 圆角刻度(8pt 基线;关键纵向节奏在视图里用 @ScaledMetric 随 Dynamic Type 缩放)
enum Space {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 36
}
enum Radius {
    /// iOS 27 方案 A：内容卡片调到 22pt，与系统浮动 chrome 的连续曲率更协调。
    static let card: CGFloat = 22
    static let chip: CGFloat = 12
    static let dockExpanded: CGFloat = 26   // 录音坞(展开)
    static let pillBar: CGFloat = 20        // 胶囊条(跨页录音)
    static let iconTile: CGFloat = 8        // 设置图标 tile
    static let stopKeyInner: CGFloat = 3.5  // 停止键内方块
}

// MARK: - 字体层级(静墨 Quiet Ink 排版令牌;系统字体 SF Pro/PingFang SC)
// 层次靠字重 + 字号 + 行距,不靠颜色。计时数字用 .monospacedDigit() 单独在调用处加。
extension View {
    /// Large Title:34/41 Bold,tracking −2%(页面大标题)
    func quietLargeTitle() -> some View {
        font(.system(size: 34, weight: .bold)).tracking(-0.68)
    }
    /// Title 2:22/28 Semibold,tracking −1.2%(弹层标题)
    func quietTitle2() -> some View {
        font(.system(size: 22, weight: .semibold)).tracking(-0.26)
    }
    /// Headline:17/22 Semibold(状态文案,如「正在聆听 · 识别中」)
    func quietHeadline() -> some View {
        font(.system(size: 17, weight: .semibold))
    }
    /// Body:17pt,行高 26pt(≈1.53),Regular——备忘正文、待办项
    func quietBody() -> some View {
        font(.system(size: 17, weight: .regular)).lineSpacing(4)
    }
    /// Footnote:13/18 Regular,inkSecondary(时长、提示)
    func quietFootnote() -> some View {
        font(.system(size: 13, weight: .regular)).foregroundStyle(Theme.textSecondary)
    }
    /// Section Label:11/14 Semibold,tracking +5%,uppercase,inkTertiary(日期分组头、设置分区头)
    func quietSectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold))
            .tracking(0.55)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - 静态波形刻度(装饰性;录音坞待机态左侧/按钮内图形。圆头、3pt 宽、间距 3 统一语言)
struct StaticWaveformTicks: View {
    var count: Int = 4
    var color: Color = Theme.textTertiary
    var tickWidth: CGFloat = 2.5
    var heights: [CGFloat] = [10, 16, 12, 7]
    var body: some View {
        QuietInkWaveformTicks(
            heights: (0..<count).map { heights[$0 % heights.count] },
            color: color,
            tickWidth: tickWidth,
            spacing: 3
        )
    }
}

// MARK: - 实时滚动波形(录音坞展开态;规格 §Screens.2 + 设计稿 2c:3pt 圆头刻度、间距 3、高 6–34)
//
// 数据源:DictationController.audioLevel(@Published,由 Recorder.onLevel 的 RMS→dB→0…1 经
// attack/release 包络得到;VAD 静音自动停用的就是同一信号,这里纯复用,不碰采集逻辑)。
// 观感目标 = 设计稿 2c:稀疏、参差、多彩的独立刻度,**不是连续条**——
//  ① 每根固定 3pt 宽 + 间距 3,`.fixedSize()` 锁死总宽,绝不拉伸填满容器;
//  ② 采样时 sqrt 提对比(常规语音落在中段) + 每根 ±独立参差(包络太平滑会连成一条);
//  ③ 逐根按自身高度着色:低 → accent@0.4,中 → accent 实色,峰 → textPrimary(深色 ≈ #EAE6DE 近白)。
// accessibilityReduceMotion:退化为静态参差刻度(不滚动不跳动,着色规则相同)。
struct LiveWaveformTicks: View {
    var level: Float                      // 0...1,当前响度(外部 @Published 驱动重渲染)
    var tickCount: Int = 19
    var tickWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 6
    var maxHeight: CGFloat = 34

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Float] = []
    private let sampler = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()  // ~20Hz

    /// 减弱动态效果时的静态刻度样式(参差、中间偏高,与 2c 版面一致;不动)
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
        .fixedSize()               // 19 × 3pt + 18 × 3pt 间距 = 固定 111pt,居中,不许拉伸
        .frame(height: maxHeight)
        .onReceive(sampler) { _ in
            guard !reduceMotion else { return }
            // 成形:sqrt 拉开中段对比(0.1→0.32、0.3→0.55、0.5→0.71),
            // 再乘每根独立的 ± 参差因子——包络信号 20Hz 下相邻样本高度相关,
            // 不加参差会平滑成"连续条",与 2c 的参差刻度观感不符。
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
        // history 不足 tickCount 时左侧留静音位,让波形从右侧"长出来"
        let offset = i - (tickCount - history.count)
        guard offset >= 0, offset < history.count else { return 0 }
        return history[offset]
    }

    private func tickHeight(_ v: Float) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(min(1, max(0, v)))
    }

    /// 逐根三档着色(对照 2c:19 根中近白 2-3 根、纯 accent 实色多根、其余半透明分层):
    /// 峰(≥0.8)→ textPrimary(深色≈近白/浅色=墨);中(≥0.5)→ accent 实色;低 → accent 半透明随高度加实。
    /// 目标观感:蓝白相间、层次分明——参差因子(0.5–1.35)保证常规语音每帧有 1-3 根冲上近白档。
    private func tickColor(_ v: Float) -> Color {
        let v = Double(min(1, max(0, v)))
        if v >= 0.8 { return Theme.onGlassInk }
        if v >= 0.5 { return Theme.accentOnGlass }
        return Theme.accentOnGlass.opacity(0.35 + 0.8 * v)
    }
}

// MARK: - Liquid Glass 录音坞背景
//
// 方案 A 的硬约束：玻璃只放进现有视图的 background，不包新布局容器，
// 因此不会改变 RecordButton 的 frame / z 序 / Link 叠层和命中测试链。
// iOS 26+（含 iOS 27）使用系统 glassEffect；旧系统保留 .regularMaterial。
private struct DockMaterialModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background { dockBackground }
    }

    @ViewBuilder
    private var dockBackground: some View {
        if reduceTransparency {
            shape
                .fill(Theme.reducedTransparencyFill)
                .overlay(shape.strokeBorder(Theme.onGlassInk.opacity(0.14), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            if let tint {
                shape.fill(.clear).glassEffect(.regular.tint(tint), in: shape)
            } else {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            }
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }
}
extension View {
    func dockMaterial<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(DockMaterialModifier(shape: shape, tint: tint))
    }
}

// MARK: - 系统 chrome 的减弱透明度兜底

private struct QuietInkNavigationChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .toolbarBackground(Theme.reducedTransparencyFill, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct QuietInkTabChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .toolbarBackground(Theme.reducedTransparencyFill, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        } else {
            content
        }
    }
}

extension View {
    func quietInkNavigationChrome() -> some View { modifier(QuietInkNavigationChromeModifier()) }
    func quietInkTabChrome() -> some View { modifier(QuietInkTabChromeModifier()) }
}

// MARK: - 触觉(只在因果时刻触发,与视觉同帧;不滥用)
/// 后台可用的震动提示。
///
/// 下面的 `Haptics`(UIFeedbackGenerator)**只在前台有效** —— 而本项目最需要提示的
/// 那个场景恰恰不在前台:待命开着、App 在后台、用户在别的 App 里按 Action Key。
/// AudioToolbox 的 system sound 不依赖前台,也不经过录音用的无输出 `.record` 会话。
///
/// **用震动而不是提示音**:2026-09-02 真机实测,Live Activity 的
/// `AlertConfiguration(sound: .default)` 发出去了(日志有"起录提示已发出")但完全没有
/// 声音 —— 静音键会吃掉它。震动在静音模式下仍然保留。
///
/// **首尾次数必须不同**。用户原话:"灵动岛短暂展开这一下,不能确认是录音开始了
/// 还是录音在结束,所以光是短暂展开没有任何意义。"一个不可区分的信号等于没有信号。
/// 约定:起录一下,收尾两下。
enum BackgroundCue {
    static func buzz(times: Int = 1) {
        guard times > 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(kSystemSoundID_Vibrate) {
            guard times > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                buzz(times: times - 1)
            }
        }
    }
}

enum Haptics {
    static func impact(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
    static func notify(_ t: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(t)
    }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
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

// MARK: - 卡片表面(方案 A：实色 + 0.5pt 描边，不再使用常态阴影)
struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.card
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}
extension View {
    func cardSurface(radius: CGFloat = Radius.card) -> some View { modifier(CardSurface(radius: radius)) }
}

// MARK: - 「材质化」进出转场(从触发处生长:blur/scale/opacity 一起动,读起来是真实材质到达)
extension AnyTransition {
    /// 从底部锚点生长的材质化转场;减弱动态效果时退化为交叉淡入(在视图里判断后择一)。
    static var materialize: AnyTransition {
        .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
    }
}

// MARK: - 撤销横幅(对破坏性操作的宽容:删除后 4 秒内可撤销)
struct PendingUndo: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let undo: () -> Void
    static func == (a: PendingUndo, b: PendingUndo) -> Bool { a.id == b.id }
}

private struct UndoBannerModifier: ViewModifier {
    @Binding var pending: PendingUndo?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let p = pending {
                HStack(spacing: Space.md) {
                    Text(p.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Space.sm)
                    Button("撤销") {
                        Haptics.impact(.light)
                        p.undo()
                        withAnimation(Motion.standard) { pending = nil }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm + 2)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, 120)   // 浮在底部录音坞之上
                .transition(reduceMotion ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                .task(id: p.id) {
                    // 4 秒后自动收起(新 undo 到来会以新 id 重启本任务、取消旧的)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation(Motion.standard) { pending = nil }
                }
            }
        }
        .animation(Motion.standard, value: pending)
    }
}
extension View {
    func undoBanner(_ pending: Binding<PendingUndo?>) -> some View { modifier(UndoBannerModifier(pending: pending)) }
}

// MARK: - 正在录音的脉动红点(让「录音进行中」状态一眼可辨;减弱动态效果时为静态实心点)
/// opacity 1→0.35,~1s ease-in-out 循环(规格「Interactions & Motion」);可选外圈 4pt 光晕。
struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var diameter: CGFloat = 9
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

// MARK: - 录音坞主控键(可复用;录音/停止的接线保留在调用处的 action 里)
/// 待机:40pt accent 实心圆,内白色 4 根波形刻度(示意「点按开始」)。
/// 录音中:44pt recordingRed 实心圆,内 13pt 白色圆角方块(示意「点按停止」)。
/// 识别/整理中:紫灰色不可用态,内容替换为白色小型进度环。
/// 载荷接线不在此:调用方 action 里仍是既有的 controller.toggle() 流程。
struct RecordButton: View {
    let isRecording: Bool
    let isProcessing: Bool
    let action: () -> Void

    private var isActive: Bool { isRecording || isProcessing }
    private var diameter: CGFloat { isActive ? 44 : 40 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isProcessing ? Theme.processingGradient
                          : (isRecording ? Theme.dangerGradient : Theme.accentGradient))
                    .frame(width: diameter, height: diameter)
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: Radius.stopKeyInner, style: .continuous)
                        .fill(.white)
                        .frame(width: 13, height: 13)
                } else {
                    idleGlyph
                }
            }
        }
        .buttonStyle(.pressable)
        .disabled(isProcessing)
        .animation(Motion.standard, value: isRecording)
        .accessibilityLabel(isProcessing ? "正在处理，录音暂不可用"
                            : (isRecording ? "停止" : "开始口述"))
    }

    /// 待机态按钮内的白色波形刻度,与录音坞左侧静态刻度呼应(圆头、统一语言)
    private var idleGlyph: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach([6, 11, 8, 4], id: \.self) { h in
                Capsule().fill(.white).frame(width: 2.5, height: CGFloat(h))
            }
        }
    }
}
