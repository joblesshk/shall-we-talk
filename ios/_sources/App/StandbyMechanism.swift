import Foundation
import UIKit

/// 后台待命机制的统一接口。
///
/// **为什么要有这一层**:键盘扩展拿不到麦克风,录音只能在主 App 里跑,而 iOS 会在几秒内挂起
/// 后台 App —— 所以必须有个东西替主 App 持有后台调度资格。此前唯一可行的手段是把画中画
/// 当保活工具用(`PictureInPictureStandbyController`,§13),代价是要靠私有 `setControlsStyle:`
/// 压住系统重组时冒出来的横条,那条私有接口是 App Store 的硬伤。
///
/// **2026-09-08 用户决定移除 ScreenCaptureKit 这条线。** 它在 9/1 已因"每次新会话都要过
/// 一次系统共享选择器"被结案(§11.1e-CLOSED),此后一直只是包里的死选项;纯音频待命
/// (`AudioSessionStandbyController`)已经补上了"公开 API 后台待命"这个位置,而且不需要
/// 授权面板、不显示黄色录制指示。删除同时让 `UIBackgroundModes` 去掉 `screen-capture`,
/// 后台模式声明这一项审核面随之缩小。要翻旧实现用 Git(删除前最后一版见本次提交的父提交)。
///
/// 于是现存两套实现:画中画(默认)与纯音频。调用方只认这个协议。
@MainActor
protocol StandbyMechanism: AnyObject {
    /// 当前是否真的在待命(不是"用户想要待命",是"系统层面确实持有资格")
    var isActive: Bool { get }
    /// 是否正处在"被系统意外中止后的有界恢复窗口"内。桥在这个窗口里不能把旧快照当成功。
    var isRecoveringUnexpectedSystemStop: Bool { get }
    /// 待命被终止时回调(用户主动停止不走这里)
    var onStopped: (() -> Void)? { get set }

    /// 用户点击引发的启动请求。返回 false 表示这次点击不该被当成"已开始待命"。
    @discardableResult
    func requestStartFromUserAction() -> Bool
    func start() async throws
    func stop()

    /// 画中画需要一个真实的宿主视图来承载 sample-buffer layer;ScreenCaptureKit 不需要,
    /// 因此这三个方法在 SCK 实现里是空操作。保留在协议里是为了让调用方无差别。
    func attachSource(to view: UIView)
    func layoutSource(in view: UIView)
    func detachSource(from view: UIView)
}

/// 待命机制的门面:按系统版本与用户偏好选一套实现,调用方只跟它打交道。
///
/// 切换策略刻意保守 —— iOS 27 以下没得选;iOS 27 及以上**默认仍走画中画**,
/// ScreenCaptureKit 只作为设置里的显式选项存在(它要求用户先在系统选择器里授权一次,
/// 且屏幕上会常驻黄色录制指示器)。2026-08-13 用户决定把 SCK 这条线暂时封存,
/// 日常以画中画为后台保活主方式,详见 工程规划.md §11.1e-END。
@MainActor
enum StandbyController {
    /// 用户偏好键。取值:`auto`(默认,解析为画中画)、`pictureInPicture`、`audioSession`。
    static let preferenceKey = "standbyMechanismPreference"

    enum Kind: String {
        case auto
        case pictureInPicture
        /// 2026-09-08 新增:纯音频待命。没有保活工具,后台资格来自录音本身。
        /// 唯一一套不依赖任何非公开接口的机制,代价是橙点常亮(见
        /// `AudioSessionStandbyController` 头部)。默认不选中。
        case audioSession
    }

    static var preference: Kind {
        Kind(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .auto
    }

    /// 是否走纯音频待命。只有用户在设置里显式选中才为真;`auto` 不会落到这里。
    static var usesAudioSession: Bool {
        preference == .audioSession
    }

    /// **本机制是否靠 `Recorder` 的常驻热引擎提供后台起录能力。**
    ///
    /// 画中画是反例:它空闲期完全关麦,靠 PiP 场景保活,段尾不保热。
    /// 纯音频待命则相反 —— 它的后台资格**就是**那条录音会话本身。
    /// 判据按语义命名而不是"是不是某个具体实现",新机制进来时不必到处改条件。
    static var keepsRecorderHot: Bool {
        usesAudioSession
    }

    /// 本机制每次新会话是否都要用户在系统面板上重新授权一次。
    ///
    /// ScreenCaptureKit(`SCContentSharingPicker`)是唯一命中过的,而它已于 2026-09-08
    /// 删除,因此恒为 false。判据本身保留:它表达的是一个真实的机制维度,
    /// 日后若再引入这类机制可直接复用,而不是又去写"是不是某个具体实现"。
    static var requiresSystemAuthorization: Bool { false }

    /// ScreenCaptureKit 待命已删除。这个常量保留为 `false`,只为让沿用旧名的调用点
    /// (如诊断字符串)继续可读;新代码一律用上面两个语义判据。
    static var usesScreenCapture: Bool { false }

    static var shared: any StandbyMechanism {
        if usesAudioSession { return AudioSessionStandbyController.shared }
        return PictureInPictureStandbyController.shared
    }

    /// 停止所有可能仍然存活的实现，而不是按照“此刻的偏好”只停止其中一个。
    ///
    /// 教训来自 SCK 时代:偏好从 ScreenCapture 改成 PiP 后，`shared.stop()` 会解析成
    /// PiP.stop()，旧的 SCK 流因此永远收不到 stop。SCK 已删除,但这条结构性教训对
    /// 画中画↔纯音频同样成立 —— 切换机制时必须停掉**所有**实现,不能只停当前偏好那个。
    static func stopAll() {
        PictureInPictureStandbyController.shared.stop()
        AudioSessionStandbyController.shared.stop()
    }

    /// 面向用户的机制名(设置页、状态行、灵动岛文案共用,避免三处各写各的)。
    static var mechanismDisplayName: String {
        usesAudioSession ? "麦克风待命" : "画中画待命"
    }

    /// 待命运行中的状态行。两套机制的代价完全不同,必须如实各写各的:
    /// 画中画无痕但依赖私有 `setControlsStyle:`;纯音频全公开 API 但橙点常亮 ——
    /// 用户有权在状态行里就看见自己选的是哪种。
    static func standbyRunningStatus(durationLabel: String) -> String {
        if usesAudioSession {
            return "麦克风待命中 · \(durationLabel) · 橙点常亮,空闲不保存不上传"
        }
        return "画中画省电待命中 · \(durationLabel) · 已无痕运行"
    }

    /// 两套待命机制的代价互不相同，说明块必须各写各的：不能让用户在选了
    /// 「麦克风」之后仍读到「空闲时麦克风完全关闭」这种与事实相反的文案。
    static var mechanismExplanation: String {
        if StandbyController.usesAudioSession {
            return "开启后录音引擎持续运行，键盘随时可以直接开录，不需要跳回 App。\n\n"
                + "空闲期采样闸门关闭，音频缓冲在到达前就被丢弃：不落盘、不识别、不上传。\n\n"
                + "代价:系统橙色麦克风指示点在整个待命期间常亮，控制中心会显示本 App 正在使用麦克风，"
                + "其它 App 的音频会被压低。这条路不使用任何非公开接口。"
        }
        return "开启后会直接建立零高度的低帧率画中画，无需拖动或侧藏。空闲时麦克风与录音引擎均关闭。\n\n"
            + "代价:画中画会占用灵动岛槽位，因此开启期间操作按钮录音在灵动岛上不显示状态。"
    }

    static var mechanismFooter: String {
        if StandbyController.usesAudioSession {
            return "麦克风全程保持占用；空闲时不保存、不上传。结束待命即释放麦克风，橙点随之消失。"
        }
        return "空闲时麦克风和录音引擎完全关闭；从键盘唤起录音时会自动开启，录完继续保持待命。"
    }

    /// 供诊断日志用的机制名
    static var mechanismName: String {
        usesAudioSession ? "AudioSession" : "PiP"
    }
}
