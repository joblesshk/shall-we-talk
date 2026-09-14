import AppKit
import Carbon
import ShallWeTalkCore

/// 把整理稿插入当前前台 App 的光标处:剪贴板 + 模拟 Cmd+V,随后恢复原剪贴板
/// 需要 Accessibility 授权。密码框等安全输入场景系统会拦截,属已知限制
enum TextInserter {
    /// Only return to the recording's app when our own UI took the foreground.
    /// If the user selected another app, respect that currently active target.
    @MainActor
    static func prepareTarget(fallback: NSRunningApplication?) async -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let current = NSWorkspace.shared.frontmostApplication else { return false }
        if current.processIdentifier != ownPID { return true }
        guard let fallback, !fallback.isTerminated, fallback.processIdentifier != ownPID else { return false }
        guard fallback.activate(options: []) else { return false }
        for _ in 0..<5 {
            guard !Task.isCancelled else { return false }
            let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if activePID == fallback.processIdentifier { return true }
            // Never fight a deliberate switch to a third application.
            if let activePID, activePID != ownPID { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
    // Per-message bound, not an end-to-end insertion deadline. Apply only to
    // objects used here; setting it on the system-wide object changes the process.
    private static let accessibilityMessageTimeout: Float = 0.25
    /// 插入动作的真实可观察结果。很多 Web/Electron 编辑器允许系统粘贴，却不向
    /// Accessibility 暴露可回读的全文；这不是插入失败，不能据此打扰用户。
    enum InsertionResult {
        case verified
        case pasteIssuedUnverified
        case directWriteIssuedUnverified
        case failedToIssuePaste
    }

    /// 焦点元素检测结果
    enum FocusCheck {
        case editable          // 确认是文本输入区
        case notEditable(String) // 确认不是(附角色名,便于诊断)
        case unknown           // 查不出来 —— 按可插入处理(fail-open)
    }

    /// 用 Accessibility 判断焦点是否可输入文本。
    /// 关键原则:宁可放行。很多 Electron/Chromium 应用的 AX 树查询不可靠,
    /// 只有明确查到按钮/图片等"确定非文本"角色才拦截;查询失败或角色模糊一律放行,
    /// 最坏情况是空发一次 ⌘V,无害;误拦则会让正常插入失败(实测教训)。
    static func checkFocusedElement() -> FocusCheck {
        guard let element = focusedElement() else { return .unknown }

        var role = "?"
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let r = roleRef as? String { role = r }

        // 1) 明确的文本角色
        if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
            "AXSearchField", "AXWebArea"].contains(role) {
            return .editable
        }
        // 2) 支持 SelectedTextRange 的元素基本都可编辑
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           range != nil {
            return .editable
        }
        // 3) kAXValue 可写 → 可编辑
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }
        // 4) 只有这些明确的交互性非文本角色才判定"不可插入"
        //    注意:AXGroup/AXWindow/AXScrollArea 等容器角色常是 Electron 误报,归入 unknown 放行
        if ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton",
            "AXPopUpButton", "AXSlider", "AXImage", "AXStaticText", "AXLink",
            "AXDisclosureTriangle", "AXIncrementor"].contains(role) {
            return .notEditable(role)
        }
        return .unknown
    }

    /// 插入策略(内容可得性优先):
    /// 0. 完整备份剪贴板后放入识别文本；若备份失败，只尝试不改剪贴板的 AX 路径
    /// 1. 优先使用宿主自己的 ⌘V，避免 AX 写入“成功”却不上屏后无法安全重试
    /// 2. 剪贴板无法完整备份时才走 AX；结果不确定时不重复写入
    /// 3. 只有确认文本已上屏,才把用户原剪贴板还原;确认不了就保留识别文本,宁不还原不丢内容
    static func insertAtCursor(_ rawText: String,
                               completion: @escaping (InsertionResult) -> Void) {
        // 边界感知必须在选定插入路径**之前**算好:AX 直插与 ⌘V 兜底要用同一份文本,
        // 否则同一句口述会因为走了哪条路而得到不同结果。读不到光标上下文时
        // `InsertionBoundary` 自己会退回原文,不需要在这里分支。
        let text = adjustedForBoundary(rawText)
        let pb = NSPasteboard.general
        guard let saved = PasteboardSnapshot.capture(from: pb) else {
            // A promised representation may be unavailable. Preserve the original
            // clipboard; only the direct AX path is safe in that case.
            completion(directInsert(text) ?? .failedToIssuePaste)
            return
        }
        let clearedVersion = pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            saved.restore(to: pb, ifUnchangedSince: clearedVersion)
            completion(.failedToIssuePaste)
            return
        }
        let ourChangeCount = pb.changeCount

        // Normal host paste preserves the editor's own insertion/undo behavior.
        // 预先保存同一焦点元素及其值；只有该元素的值随后确实发生变化且包含本次文本，
        // 才能称为“已验证”。仅在旧值中碰巧已有相同片段不构成成功证据。
        let pasteTarget = focusedElement()
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let valueBeforePaste = pasteTarget.flatMap { stringValue(of: $0) }
        let restoreInputSource = InputSourceGuard.switchToASCIICapableIfNeeded()
        let settleDelay: TimeInterval = restoreInputSource == nil ? 0.03 : 0.12

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            // 等用户松开快捷键的修饰键再发 ⌘V,否则物理 ⌥/⌃ 会叠加成别的组合键
            performPaste(attemptsLeft: 10, isStillValid: {
                pb.changeCount == ourChangeCount && targetPID != nil &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID &&
                    sameFocusIfObservable(pasteTarget, focusedElement())
            }) { pasteIssued in
                if let restoreInputSource {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreInputSource() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    // 仅当能确认文本已出现在焦点元素里,才还原原剪贴板
                    let inserted = pasteChangedValue(
                        of: pasteTarget, from: valueBeforePaste, inserting: text)
                    if inserted { saved.restore(to: pb, ifUnchangedSince: ourChangeCount) }
                    if inserted {
                        completion(.verified)
                    } else if pasteIssued {
                        completion(.pasteIssuedUnverified)
                    } else {
                        completion(.failedToIssuePaste)
                    }
                }
            }
        }
    }

    static func sameFocusIfObservable(_ before: AXUIElement?, _ after: AXUIElement?) -> Bool {
        // Some web editors expose no AX focused element at all. In that case
        // the foreground-process guard remains the available check.
        guard let before, let after else { return before == nil }
        return CFEqual(before, after)
    }

    /// 按光标前后的既有内容微调整理稿(规则见 `InsertionBoundary`,与 iOS 键盘共用同一份)。
    ///
    /// 上下文来自焦点元素的 `kAXValue` + `kAXSelectedTextRange`。这两项在很多
    /// Electron/Chromium 应用上读不到——与 `checkFocusedElement` 的 fail-open 原则一致,
    /// 读不到就退回原文,绝不猜。有选中文本时(range.length > 0)本次插入是替换而非追加,
    /// 前后文仍按选区两侧计算。
    private static func adjustedForBoundary(_ text: String) -> String {
        guard let element = focusedElement(),
              let value = stringValue(of: element),
              let range = selectedRange(of: element) else { return text }
        let ns = value as NSString
        guard range.location != NSNotFound,
              range.location >= 0, range.location <= ns.length,
              range.length >= 0, range.location + range.length <= ns.length else { return text }
        return InsertionBoundary.adjust(
            text: text,
            before: ns.substring(to: range.location),
            after: ns.substring(from: range.location + range.length))
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// AX 直插 + 回读验证:写入前后都读 kAXValue,确认文本真的进去了才算成功
    /// Once a write succeeds, never repeat it merely because readback is unavailable.
    private static func directInsert(_ text: String) -> InsertionResult? {
        guard let element = focusedElement() else { return nil }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let before = stringValue(of: element) else { return nil }

        let writeStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if writeStatus == .cannotComplete {
            // A messaging timeout does not establish that the target did not
            // perform the write. Do not follow an ambiguous write with Cmd-V.
            return .directWriteIssuedUnverified
        }
        guard writeStatus == .success else { return nil }

        return directWriteOutcome(before: before, after: stringValue(of: element), text: text)
    }

    static func directWriteOutcome(before: String, after: String?, text: String) -> InsertionResult {
        guard let after, after != before, after.contains(text) else {
            return .directWriteIssuedUnverified
        }
        return .verified
    }

    /// 用粘贴前后同一个 AX 元素的值变化确认上屏。读不到旧值、焦点控件不暴露全文，
    /// 或值没有变化时均只能归入“已发出粘贴但无法验证”。
    private static func pasteChangedValue(of element: AXUIElement?, from before: String?,
                                          inserting text: String) -> Bool {
        guard let element, let before, let after = stringValue(of: element),
              after != before else { return false }
        return after.contains(text)
    }

    private static func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, accessibilityMessageTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, accessibilityMessageTimeout)
        return element
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else { return nil }
        return valueRef as? String
    }

    /// 修饰键(⌘⌥⌃⇧)全部松开后才发送 ⌘V;最多等 0.5 秒
    static func performPaste(attemptsLeft: Int,
                                     isStillValid: @escaping () -> Bool,
                                     modifiersHeld: @escaping () -> Bool = {
                                         !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                                     },
                                     issuePaste: @escaping () -> Bool = { pasteKeystroke() },
                                     completion: @escaping (Bool) -> Void) {
        guard isStillValid() else { completion(false); return }
        if !modifiersHeld() {
            completion(issuePaste())
        } else if attemptsLeft <= 0 {
            completion(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                performPaste(attemptsLeft: attemptsLeft - 1, isStillValid: isStillValid,
                             modifiersHeld: modifiersHeld, issuePaste: issuePaste,
                             completion: completion)
            }
        }
    }

    /// 返回值只代表系统粘贴按键事件已成功创建并发出；目标控件是否接受该事件，
    /// 只有支持 AX 回读的控件才能进一步验证。
    private static func pasteKeystroke() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        guard let down, let up else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// 输入法切换保护(Carbon Text Input Source Services)
/// 只做临时切换并保证恢复,不改变用户输入环境
enum InputSourceGuard {
    /// 当前输入法非 ASCII-capable 时,切到 ABC/US(或第一个可用 ASCII 布局)
    /// 返回恢复闭包;nil = 无需切换或切换失败(调用方按原逻辑继续)
    static func switchToASCIICapableIfNeeded() -> (() -> Void)? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        if boolProperty(current, kTISPropertyInputSourceIsASCIICapable) { return nil }
        guard let target = findASCIICapableSource(),
              TISSelectInputSource(target) == noErr else { return nil }
        return {
            // Do not undo an input-source choice the user made while we waited.
            guard let active = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  sourceID(active) == sourceID(target) else { return }
            TISSelectInputSource(current)
        }
    }

    private static func findASCIICapableSource() -> TISInputSource? {
        guard let cfList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
        let sources = cfList as! [TISInputSource]
        let candidates = sources.filter {
            boolProperty($0, kTISPropertyInputSourceIsASCIICapable)
                && boolProperty($0, kTISPropertyInputSourceIsEnabled)
                && boolProperty($0, kTISPropertyInputSourceIsSelectCapable)
        }
        if let abc = candidates.first(where: { sourceID($0) == "com.apple.keylayout.ABC" }) { return abc }
        if let us = candidates.first(where: { sourceID($0) == "com.apple.keylayout.US" }) { return us }
        return candidates.first
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
