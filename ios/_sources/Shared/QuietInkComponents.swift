import Combine
import SwiftUI

enum QuietInkKeyboardFace: Equatable {
    case voice
    case keyboard
}

/// Quiet Ink 全局波形语言：圆头、等宽、等间距，可选择中心或底部对齐。
/// 主 App、键盘语音键与右上 Switch 均复用这一实现。
struct QuietInkWaveformTicks: View {
    var heights: [CGFloat]
    var opacities: [Double] = []
    var color: Color
    var tickWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var alignment: VerticalAlignment = .center

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(color.opacity(opacity(at: index)))
                    .frame(width: tickWidth, height: height)
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(at index: Int) -> Double {
        guard !opacities.isEmpty else { return 1 }
        return opacities[index % opacities.count]
    }
}

enum QuietInkRecordButtonState: Equatable {
    /// ① 未就绪:主 App 后台录音服务未启动 / 冷启动中。整态不出现静蓝。
    case unavailable
    /// ② 就绪待按
    case idle
    /// ③ 录音中。带计时文本——设计稿把计时放进卡片内部,不再由外层状态行承担。
    case recording(clock: String)
    /// ④ 整理中,进度以整卡填充推进
    case processing(progress: CGFloat)
    /// ④ → ② 之间的插入确认对勾
    case inserted
}

/// 单行五键控制行使用的紧凑录音键。旧的 `QuietInkRecordButton` 保留给历史组件，
/// 新键盘入口使用本组件以确保录音键始终是 52pt 高、状态只改变内容与底色。
enum QuietInkVoiceControlRecordState: Equatable {
    case unavailable
    case idle
    case recording(clock: String)
    case processing
}

private extension QuietInkVoiceControlRecordState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

struct QuietInkVoiceControlRecordButton: View {
    let state: QuietInkVoiceControlRecordState
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationPhase = false

    static let height: CGFloat = 52
    static let cornerRadius: CGFloat = 15

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(background)

            content
                .foregroundStyle(foreground)
                .transition(reduceMotion ? .identity : .opacity)
        }
        .frame(height: Self.height)
        .animation(.easeInOut(duration: 0.18), value: state)
        .task(id: state) {
            guard !reduceMotion, isRecording || isProcessing else { return }
            animationPhase = false
            await Task.yield()
            animationPhase = true
        }
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch state {
        case .idle: return Color(uiColor: QuietInkVoiceControlPalette.recordIdleFill)
        case .unavailable: return Color(uiColor: QuietInkVoiceControlPalette.recordOffFill)
        case .recording: return Color(uiColor: QuietInkVoiceControlPalette.accent)
        case .processing: return Color(uiColor: QuietInkVoiceControlPalette.processing)
        }
    }

    private var foreground: Color {
        switch state {
        case .idle: return Color(uiColor: QuietInkVoiceControlPalette.accentDeep)
        case .unavailable: return Color(uiColor: QuietInkVoiceControlPalette.recordOffFg)
        case .recording: return Color(uiColor: QuietInkVoiceControlPalette.onAccent)
        case .processing: return Color(uiColor: QuietInkVoiceControlPalette.onProcessing)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .unavailable:
            HStack(spacing: 8) {
                Image(systemName: state.isIdle ? "mic.fill" : "mic.slash")
                    .font(.system(size: 20, weight: .medium))
                Text("录音")
                    .font(.system(size: 15, weight: .medium))
            }
        case .recording(let clock):
            HStack(spacing: 10) {
                waveform
                Text(clock)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
            }
        case .processing:
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.6 : (animationPhase ? 1 : 0.22))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                            value: animationPhase
                        )
                }
                Text("整理中")
                    .font(.system(size: 15, weight: .medium))
            }
        }
    }

    private var waveform: some View {
        let delays: [Double] = [0, 0.13, 0.26, 0.39, 0.52, 0.21, 0.34]
        return HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .frame(width: 2.5, height: 22 * level(at: index))
                    .scaleEffect(y: reduceMotion ? 1 : (animationPhase ? 1 : 0.28), anchor: .center)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.525)
                            .repeatForever(autoreverses: true)
                            .delay(delays[index]),
                        value: animationPhase
                    )
            }
        }
        .frame(height: 22)
    }

    private func level(at index: Int) -> CGFloat {
        let pattern: [CGFloat] = [0.58, 0.82, 1, 0.72, 0.94, 0.68, 0.48]
        let shaped = CGFloat(pow(Double(min(1, max(0, audioLevel)) * 2.8), 0.32))
        return max(0.28, min(1, shaped * (0.72 + pattern[index] * 0.28)))
    }
}

/// 语音面的录音键。2026-08-14 按设计稿 `Voice Keyboard.dc.html` 重做为**卡片**形态。
///
/// 沿革:`216×72 胶囊` →(2026-08-05 交接稿)`88×88 圆键` →(2026-08-14)`可拉伸胶囊长条`
/// → 本次 `108pt 高的圆角卡片`。四态几何仍然全程不变——恒为一张 `cardHeight` 高、
/// `cornerRadius` 圆角的卡片,只有卡片内的内容在变。
///
/// 交接稿 v3 的两处美学细节:
/// ① **三态底色各异**,这是状态识别的主要信号——待命 `#F2EFE9` 暖奶白、录音 `#DFE9F4`
///    accent 淡染(另加内描边与外发光)、整理 `#EFECE6` 中性纸色,过渡 260ms;
/// ② **整理进度改为整卡由左向右填充**,不再是底部细条;内容浮在填充之上,圆角负责裁切。
struct QuietInkRecordButton: View {
    let state: QuietInkRecordButtonState
    /// 0...1,当前响度包络(取自 `DictationController.audioLevel`,键盘态经
    /// `KeyboardBridgeSnapshot.audioLevel` 跨进程同步)。取代此前与输入完全无关、
    /// 靠各柱各自计时循环的"随机跳动"波形——那套动画和用户是否在说话没有任何关系,
    /// 用户没法靠它判断录音有没有真的收到声音。
    var audioLevel: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    @State private var recordingRing = false

    /// 卡片几何,取自设计稿:height 108 / border-radius 18。
    static let cardHeight: CGFloat = 108
    static let cornerRadius: CGFloat = 18

    /// 卡片内配色(交接稿 v2 §3)。奶白卡片底上 `#8AABD1` 对比不足,因此卡片内部一律使用
    /// 它的派生深色 `#47708F / #426A88 / #3B6180`。**不得**再出现旧稿的 #3E6FB8 / #F5F0E7。
    private static let inkOnCard = Color(red: 26 / 255, green: 29 / 255, blue: 33 / 255)
    private static let wave = Color(red: 0x47 / 255, green: 0x70 / 255, blue: 0x8F / 255)
    private static let waveMid = Color(red: 0x42 / 255, green: 0x6A / 255, blue: 0x88 / 255)
    private static let waveStrong = Color(red: 0x3B / 255, green: 0x61 / 255, blue: 0x80 / 255)
    private static let recordDot = Color(red: 0xC0 / 255, green: 0x57 / 255, blue: 0x3F / 255)
    /// 三态底色**必须不同**——交接稿 v3 把它定为状态识别的主要信号,过渡 260ms。
    private static let cardReady = Color(red: 0xF2 / 255, green: 0xEF / 255, blue: 0xE9 / 255)
    private static let cardRecording = Color(red: 0xDF / 255, green: 0xE9 / 255, blue: 0xF4 / 255)
    private static let cardOrganizing = Color(red: 0xEF / 255, green: 0xEC / 255, blue: 0xE6 / 255)
    /// accent(#8AABD1)的描边与外发光。
    private static let accentLine = Color(red: 0x8A / 255, green: 0xAB / 255, blue: 0xD1 / 255)
    /// 整卡进度填充:左浅右深,右缘一条亮线。
    private static let fillStart = Color(red: 0x8A / 255, green: 0xAB / 255, blue: 0xD1 / 255).opacity(0.38)
    private static let fillEnd = Color(red: 0x8A / 255, green: 0xAB / 255, blue: 0xD1 / 255).opacity(0.60)
    private static let fillEdge = Color(red: 0x5B / 255, green: 0x85 / 255, blue: 0xAB / 255).opacity(0.55)

    /// ② 就绪:7 根静态波形,中间最高(设计稿 12/20/30/38/28/18/11)。
    private static let idleHeights: [CGFloat] = [12, 20, 30, 38, 28, 18, 11]
    private static let idleOpacities: [Double] = [0.32, 0.48, 0.72, 1, 0.72, 0.48, 0.32]

    var body: some View {
        ZStack {
            cardBackground
            // 整卡进度填充:由左向右填满整张卡,内容浮在其上(交接稿 v3 §4.3)。
            progressFill
            cardContent
        }
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            // 内描边:录音态 1.5pt @75%,整理态 1pt @40%,待命态无。
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Self.accentLine.opacity(strokeOpacity), lineWidth: strokeWidth)
        }
        .background {
            // 录音态的 3pt 外发光(CSS `0 0 0 3px rgba(138,171,209,.12)` 是零模糊的扩散环,
            // 这里用一张外扩 3pt 的同形圆角矩形还原,不能用 shadow——那会带模糊)。
            RoundedRectangle(cornerRadius: Self.cornerRadius + 3, style: .continuous)
                .fill(Self.accentLine.opacity(isRecording ? 0.12 : 0))
                .padding(-3)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .task(id: state) { updateAnimations() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: stateKind)
        .accessibilityHidden(true)
    }

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private var cardBackground: some View {
        let color: Color
        switch state {
        case .recording: color = Self.cardRecording
        case .processing: color = Self.cardOrganizing
        default: color = Self.cardReady
        }
        return RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(color)
    }

    private var strokeWidth: CGFloat {
        switch state {
        case .recording: return 1.5
        case .processing: return 1
        default: return 0
        }
    }

    private var strokeOpacity: Double {
        switch state {
        case .recording: return 0.75
        case .processing: return 0.4
        default: return 0
        }
    }

    /// 整卡进度填充。宽度 = progress,右缘 1pt 亮线;圆角由外层 clipShape 负责裁切。
    private var progressFill: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [Self.fillStart, Self.fillEnd],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * progressFraction)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Self.fillEdge)
                        .frame(width: 1)
                        .opacity(progressFraction > 0 ? 1 : 0)
                }
                .animation(reduceMotion ? nil : .linear(duration: 0.14), value: progressFraction)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch state {
        case .unavailable:
            VStack(spacing: 10) {
                ticks(heights: Self.idleHeights, opacities: Self.idleOpacities,
                      color: Self.inkOnCard.opacity(0.28))
                caption("正在唤醒麦克风", opacity: 0.5)
            }
        case .idle:
            VStack(spacing: 10) {
                ticks(heights: Self.idleHeights, opacities: Self.idleOpacities, color: Self.wave)
                caption("点一下开始", opacity: 0.5)
            }
        case .recording(let clock):
            VStack(spacing: 10) {
                QuietInkLevelWaveform(level: shapedLevel)
                HStack(spacing: 7) {
                    Circle()
                        .fill(Self.recordDot)
                        .frame(width: 6, height: 6)
                        .scaleEffect(!reduceMotion && recordingRing ? 1.25 : 1)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: true),
                            value: recordingRing)
                    Text(clock)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Self.inkOnCard.opacity(0.62))
                    Text("点一下结束")
                        .font(.system(size: 13))
                        .foregroundStyle(Self.inkOnCard.opacity(0.34))
                }
            }
        case .processing:
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    skeletonBar(widthFraction: 1)
                    skeletonBar(widthFraction: 0.74)
                }
                .frame(width: 150, height: 44, alignment: .center)
                caption("正在整理文字…", opacity: 0.55)
            }
        case .inserted:
            VStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Self.waveStrong)
                    .frame(height: 40)
                caption("已插入光标处", opacity: 0.5)
            }
        }
    }

    private var progressFraction: CGFloat {
        if case .processing(let progress) = state { return min(1, max(0, progress)) }
        return 0
    }

    private func caption(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 13))
            .kerning(0.3)
            .foregroundStyle(Self.inkOnCard.opacity(opacity))
    }

    /// 设计稿的静态波形(待命/唤醒态):7 根 5pt 宽、r3、间距 5 的圆头竖条,固定高度。
    private func ticks(heights: [CGFloat], opacities: [Double], color: Color) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(Self.barColor(at: index, base: color))
                    .opacity(opacities[index % opacities.count])
                    .frame(width: 5, height: height)
            }
        }
        .frame(height: 40)
    }

    /// 视觉增益 + 响应曲线,先把 `audioLevel` 拉到能用的范围,再交给 `QuietInkLevelWaveform`
    /// 做参差/滚动。不碰 `DictationController.ingestAudioLevel` 里的响度包络本身——App 侧
    /// 已经拆出一份不参与判停、攻释更快的 `visualLevel` 专供这里用。实测日常说话音量很难
    /// 把 `audioLevel`(-50dB→0、-10dB→1 的映射,见 Recorder.swift)推过 0.5,这里先乘增益
    /// 再开更陡的指数拉开安静段的对比。代价是响度较高时提前顶到满高度(压缩),
    /// 换来日常音量下摆动明显——这是特意的取舍,不是精度问题。增益/指数是经验值,
    /// 不够可以继续调。
    private static let visualGain: Float = 2.8
    private static let visualCurveExponent: Float = 0.32
    private var shapedLevel: Float {
        let boosted = min(1, max(0, audioLevel) * Self.visualGain)
        return pow(boosted, Self.visualCurveExponent)
    }

    /// 第 4 根(中间)最深,第 3/5 根次深,其余用基色——交接稿 §4.1/§4.2 的逐根配色。
    private static func barColor(at index: Int, base: Color) -> Color {
        switch index {
        case 3: return waveStrong
        case 2, 4: return waveMid
        default: return base
        }
    }

    /// ④ 整理态的骨架条 + 扫光,对应设计稿的 shimmer。
    private func skeletonBar(widthFraction: CGFloat) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width * widthFraction
            Capsule()
                .fill(Color(red: 59 / 255, green: 97 / 255, blue: 128 / 255).opacity(0.15))
                .frame(width: width)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Self.wave.opacity(0), Self.wave.opacity(0.55), Self.wave.opacity(0)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * 0.55)
                        .offset(x: !reduceMotion && shimmer ? width : -width * 0.55)
                        .animation(
                            reduceMotion ? nil : .linear(duration: 1.25).repeatForever(autoreverses: false),
                            value: shimmer)
                        .clipShape(Capsule())
                }
                .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private var stateKind: Int {
        switch state {
        case .unavailable: return 0
        case .idle: return 1
        case .recording: return 2
        case .processing: return 3
        case .inserted: return 4
        }
    }

    private func updateAnimations() {
        if case .recording = state {
            recordingRing = !reduceMotion
        } else {
            recordingRing = false
        }
        if case .processing = state {
            shimmer = !reduceMotion
        } else {
            shimmer = false
        }
    }
}

/// 录音态波形,算法直接照搬主 App `LiveWaveformTicks`(App/DesignSystem.swift)——
/// 20Hz 自采样 + 每采样独立参差(0.5–1.35 倍随机)+ 滚动历史,而不是"瞬时响度按固定
/// 权重映射到 7 根柱子"。这是它显得"活"的关键差异:参差让响度短暂不变时柱子也在
/// 小幅摇摆,固定权重映射在响度不变时会整体定住——键盘这边两轮反馈("过于平缓"/
/// "增幅不够明显")换了增益、曲线、动画时长都没解决,根子在这里,不在参数。
/// 主 App 那份用户认可"大致能看出正在说话",这里原样搬算法,只是颜色改用键盘卡片
/// 自己的 Quiet Ink 配色——不引入 `Theme`(App-only,VoicePenKeyboard target 没编译)。
private struct QuietInkLevelWaveform: View {
    /// 0...1,已经过外层增益/曲线处理(见 `QuietInkRecordButton.shapedLevel`)。
    var level: Float
    var tickCount = 7
    var tickWidth: CGFloat = 5
    var spacing: CGFloat = 5
    var minHeight: CGFloat = 8
    var maxHeight: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Float] = []
    private let sampler = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private static let wave = Color(red: 0x47 / 255, green: 0x70 / 255, blue: 0x8F / 255)
    private static let waveMid = Color(red: 0x42 / 255, green: 0x6A / 255, blue: 0x88 / 255)
    private static let waveStrong = Color(red: 0x3B / 255, green: 0x61 / 255, blue: 0x80 / 255)

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<tickCount, id: \.self) { i in
                let v = sample(at: i)
                Capsule()
                    .fill(barColor(at: i))
                    .frame(width: tickWidth, height: minHeight + (maxHeight - minHeight) * CGFloat(v))
            }
        }
        .frame(height: maxHeight)
        .onReceive(sampler) { _ in
            guard !reduceMotion else { return }
            // 参差:响度信号相邻采样天然相关,不加参差会糊成一条连续柱,和"看得出来
            // 在跳"的目的相反——与主 App 版本同一手法、同一理由。
            let jittered = min(1, max(0, level) * Float.random(in: 0.5...1.35))
            var next = history
            if next.count >= tickCount { next.removeFirst(next.count - tickCount + 1) }
            next.append(jittered)
            history = next
        }
        .animation(.linear(duration: 0.05), value: history)
        .accessibilityHidden(true)
    }

    private func sample(at i: Int) -> Float {
        if reduceMotion { return 0.4 }
        // history 不足 tickCount 时左侧留静音位,让波形从右侧"长出来"(同主 App 版本)。
        let offset = i - (tickCount - history.count)
        guard offset >= 0, offset < history.count else { return 0 }
        return history[offset]
    }

    private func barColor(at index: Int) -> Color {
        switch index {
        case 3: return Self.waveStrong
        case 2, 4: return Self.waveMid
        default: return Self.wave
        }
    }
}

/// Turn 5 定稿的双段胶囊 Switch。外框恒为 63×34pt，两段恒为 29×29pt。
struct QuietInkKeyboardFaceSwitch: View {
    let selection: QuietInkKeyboardFace
    var isEnabled = true
    let onSelect: (QuietInkKeyboardFace) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard isEnabled else { return }
            onSelect(selection == .voice ? .keyboard : .voice)
        } label: {
            HStack(spacing: 0) {
                segmentLabel(.voice)
                segmentLabel(.keyboard)
            }
            .padding(2.5)
            .frame(width: 63, height: 34)
            .background(QuietInkPalette.color(.switchTrack), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? .easeInOut(duration: 0.16)
                                : .spring(response: 0.35, dampingFraction: 1),
                   value: selection)
        .accessibilityLabel("输入界面切换")
        .accessibilityValue(selection == .voice ? "当前为语音输入界面" : "当前为键盘输入界面")
        .accessibilityHint(selection == .voice ? "轻点切换到键盘输入" : "轻点切换到语音输入")
    }

    private func segmentLabel(_ face: QuietInkKeyboardFace) -> some View {
        Group {
            if face == .voice {
                QuietInkWaveformTicks(
                    heights: [4, 9, 6, 3],
                    color: glyphColor(for: face),
                    tickWidth: 2.2,
                    spacing: 3.1
                )
                .frame(width: 16, height: 10)
            } else {
                QuietInkKeyboardOutlineGlyph(color: glyphColor(for: face))
                    .frame(width: 17, height: 12)
            }
        }
        .frame(width: 29, height: 29)
        .background(selection == face ? QuietInkPalette.color(.accent) : .clear,
                    in: Circle())
    }

    private func glyphColor(for face: QuietInkKeyboardFace) -> Color {
        selection == face
            ? QuietInkPalette.color(.accentGlyph)
            : QuietInkPalette.color(.ink).opacity(0.42)
    }
}

private struct QuietInkKeyboardOutlineGlyph: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.6, style: .continuous)
                .stroke(color, lineWidth: 1.6)
            HStack(spacing: 2.3) {
                ForEach(0..<4, id: \.self) { _ in
                    Circle().fill(color).frame(width: 2, height: 2)
                }
            }
            .offset(y: -2)
            Capsule()
                .fill(color)
                .frame(width: 9, height: 1.9)
                .offset(y: 3)
        }
    }
}

enum QuietInkPlaybackPillState: Equatable {
    case available(duration: String)
    case playing(elapsed: String, total: String, progress: Double)
    case archiving
    case unavailable
}

/// 待办卡片的 26pt 原音胶囊。数据与播放行为由调用方注入，组件不依赖 AudioPlayback。
struct QuietInkPlaybackPill: View {
    let state: QuietInkPlaybackPillState
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Group {
            switch state {
            case .unavailable:
                Text("旧待办 · 无原音")
                    .font(.system(size: 12))
                    .foregroundStyle(QuietInkPalette.color(.ink).opacity(0.28))
            case .archiving:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("原音处理中")
                }
                .font(.system(size: 12))
                .foregroundStyle(QuietInkPalette.color(.ink).opacity(0.45))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(QuietInkPalette.color(.ink).opacity(0.05), in: Capsule())
            case .available(let duration):
                pillButton(
                    foreground: QuietInkPalette.color(.accent),
                    background: .clear,
                    border: QuietInkPalette.color(.accent).opacity(0.40)
                ) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(duration).monospacedDigit()
                }
                .accessibilityLabel("播放原音，时长 \(duration)")
            case .playing(let elapsed, let total, let progress):
                HStack(spacing: 7) {
                    pillButton(
                        foreground: QuietInkPalette.color(.accentGlyph),
                        background: QuietInkPalette.color(.accent),
                        border: .clear
                    ) {
                        Image(systemName: "stop.fill").font(.system(size: 8))
                        Text("\(elapsed) / \(total)").monospacedDigit()
                    }
                    .accessibilityLabel("停止播放，已播放 \(elapsed)，总时长 \(total)")
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(QuietInkPalette.color(.accent).opacity(0.18))
                            Capsule()
                                .fill(QuietInkPalette.color(.accent))
                                .frame(width: proxy.size.width * min(1, max(0, progress)))
                        }
                    }
                    .frame(width: 64, height: 2.5)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                }
            }
        }
        .opacity(isDisabled ? 0.42 : 1)
    }

    private func pillButton<Label: View>(
        foreground: Color,
        background: Color,
        border: Color,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5, content: label)
                .font(.system(size: 12))
                .foregroundStyle(foreground)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 30pt 重新识别按钮；处理中原位切换为 20pt 进度环。
struct QuietInkRefineButton: View {
    let isRefining: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefining {
                    ProgressView()
                        .controlSize(.small)
                        .tint(QuietInkPalette.color(.accent))
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(QuietInkPalette.color(.ink).opacity(0.50))
                }
            }
            .frame(width: 30, height: 30)
            .background {
                if !isRefining {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(QuietInkPalette.color(.ink).opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefining)
        .accessibilityLabel(isRefining ? "正在重新识别" : "重新识别")
    }
}

/// 语音面左侧的竖列(语音二次修改-执行方略.md v2 §6.1)。
///
/// 原为"语音/键盘"双 tab 键(交接稿 v2 §2)。改版压成**单键面切换 + 修改键**:
/// 上键点一下切到另一个面(图标显示切换目标,与字母面顶栏 123/ABC 切换键同一习惯——
/// 当前态在语音面上是自明的,不需要再靠高亮指示),下键是修改键。外框尺寸不变
/// (58×108,键高 50、圆角 15、列内间距 8),与右侧删除/输出列继续左右对称。
struct QuietInkFaceColumn: View {
    let selection: QuietInkKeyboardFace
    var isEnabled = true
    /// 修改键的可用性与面切换键分开控制:面切换只在"不在录音/整理"时可点,
    /// 修改键还要再叠加暖态门控 + "宿主里有可改的内容"(见 KeyboardViewController)。
    var isModifyEnabled = false
    let onSelect: (QuietInkKeyboardFace) -> Void
    var onModify: (() -> Void)? = nil

    static let columnWidth: CGFloat = 58
    static let keyHeight: CGFloat = 50
    static let keyGap: CGFloat = 8
    static let keyCornerRadius: CGFloat = 15

    private static let tabIdle = Color.white.opacity(0.06)
    private static let glyphIdle = Color.white.opacity(0.5)
    private static let glyphDisabled = Color.white.opacity(0.22)

    private var targetFace: QuietInkKeyboardFace { selection == .voice ? .keyboard : .voice }

    var body: some View {
        VStack(spacing: Self.keyGap) {
            switchKey
            modifyKey
        }
        .frame(width: Self.columnWidth)
    }

    private var switchKey: some View {
        Button {
            onSelect(targetFace)
        } label: {
            RoundedRectangle(cornerRadius: Self.keyCornerRadius, style: .continuous)
                .fill(Self.tabIdle)
                .frame(height: Self.keyHeight)
                .overlay {
                    Image(systemName: targetFace == .keyboard ? "keyboard" : "waveform")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Self.glyphIdle)
                }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(targetFace == .keyboard ? "切换到键盘模式" : "切换到语音模式")
    }

    /// 与右侧输出键同一套配色逻辑(`updateSendButtonAppearance` 的 SwiftUI 对应):
    /// 可点时 accent 实心底 + 深色 ink 图标,不可点时退回 `voiceSendIdle` 淡底。
    private var modifyKey: some View {
        Button {
            onModify?()
        } label: {
            RoundedRectangle(cornerRadius: Self.keyCornerRadius, style: .continuous)
                .fill(isModifyEnabled ? QuietInkPalette.color(.accent) : QuietInkPalette.color(.voiceSendIdle))
                .frame(height: Self.keyHeight)
                .overlay {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isModifyEnabled ? QuietInkPalette.color(.accentGlyph) : Self.glyphDisabled)
                }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isModifyEnabled)
        .accessibilityLabel("语音修改")
    }
}

/// 面切换键的形态选择:两个面各用各的控件,不共用一套摆位。
///
/// 语音面用 `QuietInkFaceColumn` 的竖列(58×108,摆左下角,与右侧删除/输出列对称);
/// 字母面回到 Turn 5 定稿的 `QuietInkKeyboardFaceSwitch` 横向胶囊(63×34,摆顶栏右上)。
/// 字母面没有修改键(语音二次修改-执行方略.md v2 §11:顶栏只有 34pt,塞不下第三颗键,
/// 且键盘态修改只在语音面场景下有意义——要改的是刚才口述插入的文字)。
///
/// 2026-08-14 修:竖列引入时被两个面无差别复用,而字母面的顶栏只有 34pt 高——
/// 108pt 的竖列在那里必然溢出并压到顶栏其余内容上。形态必须跟着面走。
struct QuietInkFaceSwitchControl: View {
    let selection: QuietInkKeyboardFace
    var isEnabled = true
    var isModifyEnabled = false
    let onSelect: (QuietInkKeyboardFace) -> Void
    var onModify: (() -> Void)? = nil

    /// 字母面顶栏里那颗胶囊的固定尺寸,供 UIKit 侧约束取用。
    static let capsuleSize = CGSize(width: 63, height: 34)

    var body: some View {
        switch selection {
        case .voice:
            QuietInkFaceColumn(selection: selection, isEnabled: isEnabled,
                               isModifyEnabled: isModifyEnabled, onSelect: onSelect, onModify: onModify)
        case .keyboard:
            QuietInkKeyboardFaceSwitch(selection: selection, isEnabled: isEnabled, onSelect: onSelect)
        }
    }
}
