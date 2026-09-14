import AppKit

// The policy test never installs event monitors or changes user preferences.
final class SettingsStore {
    var hotkeyKeyCode = 49
    var hotkeyModifiers: NSEvent.ModifierFlags = [.option]
}

@main enum HotkeyRepeatSmoke {
    static func main() {
        for repeating in [false, true] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: repeating, keyCode: 49)!
            precondition(HotkeyManager.isInitialPress(event) == !repeating)
        }
        print("PASS: initial hotkey press accepted; held-key repeat rejected")
    }
}
