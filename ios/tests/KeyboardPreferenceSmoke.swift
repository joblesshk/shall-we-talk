import Foundation

@main
struct KeyboardPreferenceSmoke {
    static func main() {
        let suffix = UUID().uuidString
        guard let store = UserDefaults(suiteName: "test.keyboard.\(suffix)") else {
            fail("无法建立隔离的 UserDefaults suite")
        }
        defer {
            store.removePersistentDomain(forName: "test.keyboard.\(suffix)")
        }

        if SharedKeyboardPreferenceStore.selectedLayout(in: store) != .twentySixKey {
            fail("缺失偏好必须默认 26 键")
        }
        store.set("broken", forKey: SharedKeyboardPreferenceStore.layoutKey)
        if SharedKeyboardPreferenceStore.selectedLayout(in: store) != .twentySixKey {
            fail("非法偏好必须回退 26 键")
        }

        SharedKeyboardPreferenceStore.setSelectedLayout(.nineKey, in: store)
        if SharedKeyboardPreferenceStore.selectedLayout(in: store) != .nineKey {
            fail("九宫格偏好未持久化")
        }
        SharedKeyboardPreferenceStore.setSelectedLayout(.twentySixKey, in: store)
        if SharedKeyboardPreferenceStore.selectedLayout(in: store) != .twentySixKey {
            fail("26 键偏好未持久化")
        }
        print("PASS: keyboard layout preference smoke tests")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
