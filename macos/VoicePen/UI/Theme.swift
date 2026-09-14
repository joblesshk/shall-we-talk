import SwiftUI
import AppKit

/// 全局视觉体系「静墨 / Quiet Ink」(macOS)：暖中性画布 + 单一沉静蓝强调，大量留白。
/// 与 iOS `Shared/Theme.swift` 色值逐一对齐，不引入新色；仅把取值方式换成 AppKit 的
/// NSAppearance 动态 NSColor(与 iOS 的 UITraitCollection 动态 UIColor 是同一思路)。
/// 明暗双一等公民：所有令牌用 Color(light:dark:) 自适应，随系统外观即时切换。
enum Theme {
    // 画布 / 表面(浅色:暖纸灰 F4F2EE + 暖白卡 FCFBF9;深色:暖炭 171614 + 抬升表面 211F1C，非纯黑)
    static let bg = Color(light: 0xF4F2EE, dark: 0x171614)              // canvas
    static let surface = Color(light: 0xFCFBF9, dark: 0x211F1C)         // card
    static let surfaceRaised = surface
    static let card = surface                                           // 兼容旧引用
    static let cardHover = surfaceRaised
    static let separator = Color.inkAdaptive(lightOpacity: 0.08, darkOpacity: 0.09)  // 0.5pt 描边
    static let border = separator                                       // 兼容旧引用

    // 文字:全部由 ink 派生(层次靠字重/字号/行距,不靠颜色),明暗各自取值
    static let textPrimary = Color.inkAdaptive(lightOpacity: 1, darkOpacity: 1)
    static let textSecondary = Color.inkAdaptive(lightOpacity: 0.55, darkOpacity: 0.48)
    static let textTertiary = Color.inkAdaptive(lightOpacity: 0.37, darkOpacity: 0.37)

    // 强调:唯一「彩色」——静蓝
    static let accent = Color(light: 0x3F6C9F, dark: 0x8AABD1)
    static let accentDeep = accent

    // 状态色:recordingRed 仅用于录音信号(脉动红点/停止键/菜单栏录音态),永不做大面积色
    static let danger = Color(light: 0xC4453D, dark: 0xC4453D)
    /// 与 iOS 保持同一语义：整理只是静蓝降低强度，不再引入第二种强调色。
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
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// 明暗自适应颜色:浅色 / 深色各给一个 hex,随系统外观(NSAppearance)切换。
    /// 用 NSColor(name:dynamicProvider:) 包一层,与 iOS 用 UIColor { trait in … } 是同一模式。
    init(light: UInt32, dark: UInt32) {
        self = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        }))
    }

    /// ink(#211F1C 浅色 / #EAE6DE 深色)派生的自适应色,浅深各给独立透明度。
    /// 用于 textSecondary/textTertiary/separator 这类「ink @ N%」令牌。
    static func inkAdaptive(lightOpacity: Double, darkOpacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(Color(hex: isDark ? 0xEAE6DE : 0x211F1C))
            return base.withAlphaComponent(isDark ? darkOpacity : lightOpacity)
        }))
    }
}
