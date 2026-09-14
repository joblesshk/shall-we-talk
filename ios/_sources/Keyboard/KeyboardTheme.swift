import UIKit

/// 静墨 Quiet Ink — 键盘扩展配色 token。所有实际色值来自与主 App 共用的
/// QuietInkAssets.xcassets；此处不再声明 RGB/hex。
enum KeyboardTheme {
    static let background = QuietInkPalette.uiColor(.keyboardBackground)
    static let letterKey = QuietInkPalette.uiColor(.letterKey)
    static let functionKey = QuietInkPalette.uiColor(.functionKey)
    /// 键帽上的字母 / 符号。系统键盘在深色下是纯白、浅色下是纯黑，不带 Quiet Ink 的暖调；
    /// 因此单独立一个 token，不复用主 App 身份色 `ink`。
    static let keyLabel = QuietInkPalette.uiColor(.keyLabel)
    static let spaceIdle = QuietInkPalette.uiColor(.voiceStatusTrack)
    static let switchTrack = QuietInkPalette.uiColor(.switchTrack)
    static let ink = QuietInkPalette.uiColor(.ink)
    static let accent = QuietInkPalette.uiColor(.accent)
    static let actionAccent = QuietInkPalette.uiColor(.actionAccent)
    static let recordingRed = QuietInkPalette.uiColor(.recordingRed)
    static let separator = QuietInkPalette.uiColor(.separator)
    /// 整理态仍属于静蓝色系，仅以透明度降级。
    static let processing = QuietInkPalette.uiColor(.accent).withAlphaComponent(0.48)
    static let voiceGlyph = QuietInkPalette.uiColor(.accentGlyph)
    static let actionAccentGlyph = QuietInkPalette.uiColor(.actionAccentGlyph)

    static func ink(alpha: CGFloat) -> UIColor { ink.withAlphaComponent(alpha) }
    static func accent(alpha: CGFloat) -> UIColor { accent.withAlphaComponent(alpha) }

    /// 语音键 / 空格条待机提示统一使用的 4 根波形刻度图形(2.4pt 圆头,比例取自设计稿
    /// 3a/3b 的 SVG:viewBox 20x15,四根竖线高度约 4/11/7/3)。用 alwaysTemplate 渲染,
    /// 颜色交给 UIButton.Configuration 的 baseForegroundColor 控制。不再使用系统 mic.fill/stop.fill。
    static func waveformImage() -> UIImage {
        let size = CGSize(width: 20, height: 15)
        let renderer = UIGraphicsImageRenderer(size: size)
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (2, 5.5, 9.5),
            (7.3, 2, 13),
            (12.6, 4, 11),
            (18, 6, 9)
        ]
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineWidth(2.4)
            cg.setStrokeColor(UIColor.black.cgColor)
            for (x, yTop, yBottom) in bars {
                cg.move(to: CGPoint(x: x, y: yTop))
                cg.addLine(to: CGPoint(x: x, y: yBottom))
            }
            cg.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// 空格条录音态的红点(6pt 实心 + 外圈 @18% 光晕),保留原色不随 tint 改变。
    static func recordingDotImage() -> UIImage {
        let size = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            recordingRed.withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
            recordingRed.setFill()
            UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 6, height: 6)).fill()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
