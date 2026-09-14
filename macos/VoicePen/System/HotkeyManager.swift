import AppKit
import Carbon.HIToolbox

/// 快捷键录制时置为 true,避免录制过程误触发
enum HotkeyCaptureState {
    static var isCapturing = false
}

/// 全局热键:按键组合从 SettingsStore 动态读取,设置里改完立即生效
/// 全局键盘监听需要 Accessibility 授权(与粘贴模拟共用同一授权)
final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onTrigger: () -> Void
    private let settings: SettingsStore

    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    init(settings: SettingsStore, onTrigger: @escaping () -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            if self?.matches(e) == true { self?.onTrigger() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            if self?.matches(e) == true { self?.onTrigger(); return nil }
            return e
        }
    }

    private func matches(_ e: NSEvent) -> Bool {
        guard !HotkeyCaptureState.isCapturing else { return false }
        guard Self.isInitialPress(e) else { return false }
        guard e.keyCode == UInt16(settings.hotkeyKeyCode) else { return false }

        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let configuredModifiers = settings.hotkeyModifiers.intersection([.command, .option, .control, .shift])
        if let standaloneModifier = Self.standaloneModifier(forKeyCode: Int(e.keyCode)) {
            // 单独的修饰键只会发送 flagsChanged；松开时 mods 会变为空，因此只在按下时触发。
            return e.type == .flagsChanged && mods == standaloneModifier && configuredModifiers == standaloneModifier
        }
        return e.type == .keyDown && mods == configuredModifiers
    }

    /// Holding a toggle shortcut must not start and immediately stop recording
    /// when macOS begins generating key-repeat events.
    static func isInitialPress(_ event: NSEvent) -> Bool {
        event.type != .keyDown || !event.isARepeat
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    // MARK: - 展示用:快捷键 → 可读字符串

    static func description(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return standaloneModifier(forKeyCode: keyCode) == nil ? s + keyName(keyCode) : s
    }

    static func keyName(_ code: Int) -> String {
        let map: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        ]
        return map[code] ?? "键码\(code)"
    }

    static func isFunctionKey(_ code: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
         kVK_F10, kVK_F11, kVK_F12].contains(code)
    }

    /// 返回该物理键对应的修饰键。左右两侧键位均作为同一快捷键处理。
    static func standaloneModifier(forKeyCode code: Int) -> NSEvent.ModifierFlags? {
        switch code {
        case Int(kVK_Command), Int(kVK_RightCommand): return .command
        case Int(kVK_Option), Int(kVK_RightOption): return .option
        case Int(kVK_Control), Int(kVK_RightControl): return .control
        case Int(kVK_Shift), Int(kVK_RightShift): return .shift
        default: return nil
        }
    }
}
