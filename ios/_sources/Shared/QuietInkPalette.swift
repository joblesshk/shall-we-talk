import SwiftUI
import UIKit

/// Asset Catalog 是 Quiet Ink 色彩的唯一事实源。此文件只提供类型安全名称，
/// 不包含任何 RGB/hex 回退，避免主 App 与键盘扩展发生配色漂移。
enum QuietInkAsset: String {
    case canvas = "QuietInkCanvas"
    case card = "QuietInkCard"
    case ink = "QuietInkInk"
    case accent = "QuietInkAccent"
    case actionAccent = "QuietInkActionAccent"
    case accentGlyph = "QuietInkAccentGlyph"
    case actionAccentGlyph = "QuietInkActionAccentGlyph"
    case recordingRed = "QuietInkRecordingRed"
    case separator = "QuietInkSeparator"
    case keyboardBackground = "QuietInkKeyboardBackground"
    case letterKey = "QuietInkLetterKey"
    case functionKey = "QuietInkFunctionKey"
    case keyLabel = "QuietInkKeyLabel"
    case voiceStatusTrack = "QuietInkVoiceStatusTrack"
    case voiceHead = "QuietInkVoiceHead"
    case voiceHeadGlyph = "QuietInkVoiceHeadGlyph"
    case voiceCapsuleTrack = "QuietInkVoiceCapsuleTrack"
    case voiceDeleteKey = "QuietInkVoiceDeleteKey"
    case voiceSendIdle = "QuietInkVoiceSendIdle"
    case switchTrack = "QuietInkSwitchTrack"
}

enum QuietInkPalette {
    static func color(_ asset: QuietInkAsset) -> Color {
        Color(asset.rawValue)
    }

    static func uiColor(_ asset: QuietInkAsset) -> UIColor {
        guard let color = UIColor(named: asset.rawValue) else {
            preconditionFailure("Missing shared Quiet Ink color asset: \(asset.rawValue)")
        }
        return color
    }
}

/// 录音键单行五键方案的专用 token。设计稿要求这一行使用比旧版
/// Quiet Ink 卡片更明确的浅蓝/灰墨对比，因此不复用旧的 108pt 卡片色值。
enum QuietInkVoiceControlPalette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32,
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let alpha = traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    static let panel = dynamic(0xF7F4EE, 0x17181A)
    static let surface = dynamic(0xFFFDF9, 0x202225)
    static let keycap = dynamic(0xFFFFFF, 0x2B2E32)
    static let keycapBorder = dynamic(0x2A2724, 0xE8E4DC, lightAlpha: 0.10, darkAlpha: 0.07)
    static let keycapDisabled = dynamic(0xEBE6DD, 0x212427)
    static let ink = dynamic(0x2A2724, 0xE8E4DC)
    static let inkDisabled = dynamic(0x2A2724, 0xE8E4DC, lightAlpha: 0.26, darkAlpha: 0.22)
    static let accent = dynamic(0x3F6C9F, 0x8AABD1)
    static let accentDeep = dynamic(0x2C4F78, 0x8AABD1)
    static let onAccent = dynamic(0xFCFBF8, 0x14171A)
    static let processing = dynamic(0x6F6A62, 0x44484D)
    static let onProcessing = dynamic(0xF5F1EA, 0xD8D3CA)
    static let recordIdleFill = dynamic(0x3F6C9F, 0x8AABD1, lightAlpha: 0.13, darkAlpha: 0.16)
    static let recordIdleEdge = dynamic(0x3F6C9F, 0x8AABD1, lightAlpha: 0.26, darkAlpha: 0.28)
    static let recordOffFill = dynamic(0x2A2724, 0xE8E4DC, lightAlpha: 0.05, darkAlpha: 0.05)
    static let recordOffFg = dynamic(0x2A2724, 0xE8E4DC, lightAlpha: 0.70, darkAlpha: 0.55)
}
