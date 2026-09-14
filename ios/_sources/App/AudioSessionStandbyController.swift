import AVFoundation
import Foundation
import UIKit

/// 后台待命的第三套实现:**不借任何外物,直接靠一条从未停用过的录音会话续命。**
///
/// **为什么这条路成立**(全部是 Apple 文档明写的公开行为):
/// - `AVAudioSession` 的 `.record` / `.playAndRecord` 文档原话——"To continue recording
///   audio when your app transitions to the background (for example, when the screen locks),
///   add the `audio` value to the `UIBackgroundModes` key"。本 App 的 Info.plist 早就声明了
///   `audio`,这不是新增能力。
/// - §11.1 记录的 `!rec` / `561145187` 限制的是**在后台新建**录音会话;一条在前台合法
///   建立、此后从未 `setActive(false)` 的会话不受它约束。这正是本机制与"后台冷激活"
///   的根本分野:我们从不冷激活,我们从不放手。
///
/// **与画中画/ScreenCaptureKit 的分工差异**:那两套是"保活工具"——它们自己不采音频,
/// 只负责让主 App 有后台调度资格,真正的麦克风另外开。本机制**没有保活工具**:
/// 后台资格就来自录音本身。因此它:
/// - 不需要私有 `setControlsStyle:`(画中画压横条用的那个);
/// - 不需要系统共享选择器(SCK 每个新会话都要用户过一次的那个);
/// - 不需要任何屏幕内容,也不占灵动岛槽位。
///
/// **代价必须写在前面,不许含糊**:麦克风全程真实占用,系统橙色隐私指示点常亮,
/// 控制中心会显示本 App 正在使用麦克风,其它 App 的音频会被压低。这是**产品取舍**,
/// 不是缺陷 —— 2026-09-08 用户在知情并对照竞品后明确接受该代价,并要求把它做成
/// 画中画之外的**另一个显式选项**,不改默认。空闲期采样闸门关闭(`Recorder.warmUp()`),
/// 缓冲在 tap 里直接丢弃,不落盘、不进 ASR/LLM、不上传。
///
/// **存活判据**:`isActive` 绝不只报"用户想待命"。§13.2 已把"进程存在≠后台可用"
/// 列为不得再犯的错误,§11.1 又补了"`start()` 没抛错≠在录音"。所以这里必须同时满足
/// "用户已开启"和"输入引擎此刻真的在跑",后者由 `DictationController` 注入的
/// `isRecorderEngineLive` 探针回答。中断让引擎停转时它立刻变 false,桥不会再发布
/// 假的"可后台起录"。
@MainActor
final class AudioSessionStandbyController: NSObject, StandbyMechanism {
    static let shared = AudioSessionStandbyController()

    /// 由 `DictationController` 在启动时注入:回答"预热/录音引擎此刻是否真的在跑"。
    /// 没注入时一律视为未存活 —— 宁可报未启动,也不报假的可用。
    var isRecorderEngineLive: (() -> Bool)?

    /// 用户是否已开启本机制。单独存在是因为它和"引擎是否在跑"是两件事:
    /// 引擎可能被中断停掉而用户并没有关待命,那种情况要走中断恢复,不是用户关闭。
    private var armed = false

    private(set) var isRecoveringUnexpectedSystemStop = false

    var isActive: Bool { armed && (isRecorderEngineLive?() ?? false) }

    var onStopped: (() -> Void)?

    enum StandbyError: LocalizedError {
        case engineNotLive

        var errorDescription: String? {
            switch self {
            case .engineNotLive:
                return "麦克风引擎没有起来,待命未开启"
            }
        }
    }

    /// 画中画必须在用户点击的调用栈里同步调 `startPictureInPicture()`(否则 AVKit 静默忽略),
    /// 所以协议里留了这个"用户动作入口"。本机制没有任何需要挂在用户手势上的系统调用 ——
    /// 音频会话的建立由 `activateStandby` 里的 `recorder.warmUp()` 完成 —— 直接返回 true。
    @discardableResult
    func requestStartFromUserAction() -> Bool { true }

    /// 调用方(`DictationController.activateStandby`)保证在此之前已经:
    /// 非录音中路径 → `recorder.teardown()` + `recorder.warmUp()`;
    /// 录音中路径(键盘冷启动自动开启)→ 引擎本来就在跑,不许拆。
    /// 所以这里只做**验收**:引擎没真的活着就失败,绝不把"我请求过了"当成"开好了"。
    func start() async throws {
        guard isRecorderEngineLive?() == true else {
            armed = false
            throw StandbyError.engineNotLive
        }
        armed = true
    }

    /// 只清本机制自己的标记。**不碰 Recorder** —— 引擎的拆除由 `deactivateStandby`
    /// 按 `teardownWhenIdle` 统一决定(录音中关待命不能掐断用户正在说的这一段)。
    func stop() {
        armed = false
    }

    // 画中画要一个真实宿主视图来承载 sample-buffer layer;本机制和 SCK 一样不需要。
    func attachSource(to view: UIView) {}
    func layoutSource(in view: UIView) {}
    func detachSource(from view: UIView) {}
}
