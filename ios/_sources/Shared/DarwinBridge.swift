import Foundation

/// 跨进程轻量信令(键盘扩展 ⇄ 主 App),基于 Darwin 通知——**系统级,无需 App Group / entitlement**。
///
/// 免费 Apple 账号无法用 App Group,这里用 Darwin 通知实现"键盘控制、App 后台录音"的信令通道:
///   - 命令(键盘 → App):start / stop
///   - 事件(App → 键盘):recording / processing / result / error / alive(心跳)
///
/// Darwin 通知**不携带数据**,只传"信号";需要传数据(识别文本)时配合剪贴板(PendingTextStore 已支持)。
/// 局限:通知不能唤醒被系统挂起/杀死的 App。App 被杀后,键盘需退回 voicepen://record 重新拉起(已兜底)。
enum DarwinBridge {
    // 命令:键盘 → App
    static let cmdStart = "org.example.showwetalk.cmd.start"
    static let cmdStop  = "org.example.showwetalk.cmd.stop"
    /// 唤醒:付费(App Group)模式下,键盘把请求写进 App Group 后再发此信号,
    /// 让 App 立刻处理这条桥请求,而不必等下一个 0.5s 轮询 tick(削掉起录前的≈0.5s 等待)。
    static let cmdKick  = "org.example.showwetalk.cmd.kick"
    /// 操作按钮 / 轻点背面 App Shortcut 已落盘一条通用语音输入请求。
    static let cmdCapture = "org.example.showwetalk.cmd.capture"
    /// 操作按钮录音中的第二次按键：只停止当前 capture，不参与开始请求竞速。
    static let cmdCaptureStop = "org.example.showwetalk.cmd.capture.stop"
    // 事件:App → 键盘
    static let evtRecording = "org.example.showwetalk.evt.recording"
    static let evtProcessing = "org.example.showwetalk.evt.processing"
    static let evtResult = "org.example.showwetalk.evt.result"   // 文本已在剪贴板,键盘可取走
    static let evtError = "org.example.showwetalk.evt.error"
    static let evtAlive = "org.example.showwetalk.evt.alive"     // App 存活心跳

    /// 发一条 Darwin 通知(系统级广播)。
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Darwin 通知观察器。C 回调无法捕获 Swift 上下文,故用实例指针 + 名称→闭包表分发。
/// 使用方持有本实例;deinit 自动注销。回调在主线程分发。
final class DarwinObserver {
    private var handlers: [String: () -> Void] = [:]
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    func observe(_ name: String, _ handler: @escaping () -> Void) {
        handlers[name] = handler
        let raw = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, raw,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { me.handlers[key]?() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    func removeAll() {
        let raw = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, raw)
        handlers.removeAll()
    }

    deinit { removeAll() }
}
