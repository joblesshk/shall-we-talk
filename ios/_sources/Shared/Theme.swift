import SwiftUI
import UIKit
import Combine

/// 全局视觉体系「静墨 / Quiet Ink」。实际色值全部来自共享 Asset Catalog；
/// 这里仅保留语义名称与透明度层级。
enum Theme {
    static let bg = QuietInkPalette.color(.canvas)
    static let surface = QuietInkPalette.color(.card)
    static let surfaceRaised = surface
    static let card = surface
    static let cardHover = surfaceRaised
    static let separator = QuietInkPalette.color(.separator)
    static let border = separator

    static let ink = QuietInkPalette.color(.ink)
    static let textPrimary = ink
    static let textSecondary = ink.opacity(0.52)
    static let textTertiary = ink.opacity(0.37)

    static let accent = QuietInkPalette.color(.accent)
    static let accentDeep = accent
    /// 系统玻璃上的高对比静蓝，浅色/深色由 trait 分流。
    static let accentOnGlass = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.612, green: 0.733, blue: 0.867, alpha: 1)
            : UIColor(red: 0.208, green: 0.376, blue: 0.561, alpha: 1)
    })
    static let glassTint = accent.opacity(0.08)
    static let onGlassInk = textPrimary
    static let reducedTransparencyFill = surface

    static let danger = QuietInkPalette.color(.recordingRed)
    /// 整理态只降低静蓝强度，不引入交接稿之外的第三种状态色。
    static let processing = accent.opacity(0.48)
    static let ok = accent
    static let warn = danger

    // 规格中强调/危险色为纯色而非渐变;两个 Gradient 令牌保留(调用处不变),内部退化为同色首尾
    static let accentGradient = LinearGradient(
        colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let dangerGradient = LinearGradient(
        colors: [danger, danger], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let processingGradient = LinearGradient(
        colors: [processing, processing], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    /// 兼容既有调用点；基色仍来自 Asset Catalog。
    static func inkAdaptive(lightOpacity: Double, darkOpacity: Double) -> Color {
        Color(uiColor: UIColor { traits in
            QuietInkPalette.uiColor(.ink)
                .resolvedColor(with: traits)
                .withAlphaComponent(traits.userInterfaceStyle == .dark ? darkOpacity : lightOpacity)
        })
    }
}

/// 真实音量驱动的波形条(深蓝):5 根竖条,中间高两侧低
/// level = 0 时保持 15% 最小高度的静态低幅,不跳动
struct WaveformBars: View {
    var level: Float                 // 0...1,已由 AppState 做过 attack/release 包络
    var barWidth: CGFloat = 5
    var maxHeight: CGFloat = 32
    var spacing: CGFloat = 4.75      // 5×5.75? 默认整体约 44×32

    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    @State private var jitter: [CGFloat] = [0, 0, 0, 0, 0]
    private let jitterTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Theme.accent.opacity(0.95))
                    .frame(width: barWidth, height: barHeight(i))
            }
        }
        .frame(width: barWidth * 5 + spacing * 4, height: maxHeight, alignment: .center)
        .animation(.linear(duration: 0.08), value: level)
        .animation(.easeOut(duration: 0.1), value: jitter)
        .onReceive(jitterTimer) { _ in
            // 有声音时加 ±4% 轻微随机抖动,更自然;静音不抖
            jitter = level > 0.02
                ? (0..<5).map { _ in CGFloat.random(in: -0.04...0.04) }
                : [0, 0, 0, 0, 0]
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let dynamic = maxHeight * Self.weights[i] * CGFloat(level) * (1 + jitter[i])
        return max(maxHeight * 0.15, dynamic) // 静音保留 15% 最小高度
    }
}
