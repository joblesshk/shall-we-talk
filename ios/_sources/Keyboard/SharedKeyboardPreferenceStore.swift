import Foundation

/// 中文文字键盘的可选布局。英文始终使用 26 键。
enum ChineseKeyboardLayout: String, CaseIterable {
    case twentySixKey
    case nineKey
}

/// 布局只由键盘扩展读取和写入。App Group 可用时用共享 suite；不可用时使用
/// 扩展自己的 standard defaults。单一 store 避免双写的一致性问题。
enum SharedKeyboardPreferenceStore {
    static let layoutKey = "chineseKeyboardLayoutV1"

    private static var store: UserDefaults { AppGroup.suite ?? .standard }

    static var selectedLayout: ChineseKeyboardLayout {
        get {
            guard let raw = store.string(forKey: layoutKey),
                  let layout = ChineseKeyboardLayout(rawValue: raw) else {
                return .twentySixKey
            }
            return layout
        }
        set {
            store.set(newValue.rawValue, forKey: layoutKey)
        }
    }

    /// 仅供纯 Foundation 冒烟测试注入隔离的 defaults。
    static func selectedLayout(in store: UserDefaults) -> ChineseKeyboardLayout {
        guard let raw = store.string(forKey: layoutKey),
              let layout = ChineseKeyboardLayout(rawValue: raw) else {
            return .twentySixKey
        }
        return layout
    }

    static func setSelectedLayout(_ layout: ChineseKeyboardLayout, in store: UserDefaults) {
        store.set(layout.rawValue, forKey: layoutKey)
    }
}
