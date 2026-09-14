import UIKit
import SwiftUI
import os

enum VoicePenURL {
    static let record = URL(string: "voicepen://record")!
    static let edit = URL(string: "voicepen://edit")!
}

private struct VoiceEntryLink: View {
    let destination: URL
    let onTap: () -> Void
    let label: String

    var body: some View {
        Link(destination: destination) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded(onTap))
        .accessibilityLabel(label)
    }
}

/// `UIInputView` 的默认固有高度会受系统上一个输入法 frame 影响。
/// 语音面只有一行五个控件，因此让输入视图自身明确报告当前面的
/// 固定高度，不让 26 键键盘的容器高度成为下一轮自适应输入。
private final class VoicePenSizingInputView: KeyboardTouchInputView {
    var contentHeight: CGFloat = 0 {
        didSet {
            guard abs(oldValue - contentHeight) >= 0.5 else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentHeight)
    }
}

/// Shall We Talk 双面键盘：默认语音面 + 完整 QWERTY 面。
/// 右上 Switch 坐标与底部功能栏保持不动，只切换中间内容。
final class KeyboardViewController: UIInputViewController {
    private static var hostMapping: HostReturnTarget?
    private var hostResolutionTask: Task<Void, Never>?
    private var hostOpeningID: UUID?
    private var reconnectDocumentID: UUID?
    private let hostReturnMessageLabel = UILabel()

    override init(nibName: String?, bundle: Bundle?) {
        SWTEnableHostIdentity()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) {
        SWTEnableHostIdentity()
        super.init(coder: coder)
    }
    private let topBar = UIView()
    private let topLeftContainer = UIView()
    private let faceContentContainer = UIView()
    private let bottomBar = UIView()
    private let voiceStatusLabel = UILabel()
    private let voiceTimerLabel = UILabel()
    private let voiceStatusDot = UIView()
    private let voiceSpinnerLayer = CAShapeLayer()
    private let voiceBrandImageView = UIImageView()
    private let voiceHeaderContent = UIView()
    private let keyboardHeaderContent = UIView()
    private let cacheLabel = UILabel()
    private let spaceButton = KeyFieldButton(type: .system)
    private static let hintIdle = "轻点说话"
    private static let hintRecording = "正在录音…"
    private static let hintRecognizing = "正在识别…"
    private static let hintProcessing = "正在整理…"
    private let deleteButton = KeyFieldButton(type: .system)
    private let symbolDeleteButton = KeyFieldButton(type: .system)
    private let voiceSwitchButton = UIButton(type: .system)
    private let voiceEditButton = UIButton(type: .system)
    private let voiceDeleteButton = UIButton(type: .system)
    private let voiceSendButton = UIButton(type: .system)
    /// 保留语音控制行和中间录音键的引用，用于在真机上对账“外框变大”
    /// 究竟是键盘容器变高，还是五个控件在宿主重挂载后被缩小。
    private let voiceControlRow = UIView()
    private weak var voiceEntryContainer: UIView?
    private let sendButton = KeyFieldButton(type: .system)
    /// 键盘面的 123 / ABC 字符页切换键；语音面使用 iOS 宿主最下方的系统输入法切换键。
    private let leftFunctionButton = KeyFieldButton(type: .system)
    private let bottomMiddleContainer = UIView()
    private let keyboardBottomContent = UIView()
    private var voiceCapsuleHost: UIHostingController<QuietInkVoiceControlRecordButton>?
    private var faceSwitchHost: UIHostingController<QuietInkFaceSwitchControl>?
    private var activeFace: QuietInkKeyboardFace = .voice
    private var keyboardFaceView: UIView?
    private var voiceFaceView: UIView?
    private var letterKeyboardView: UIView?
    private var nineKeyKeyboardView: UIView?
    private var symbolKeyboardView: UIView?
    private enum KeyboardCharacterPage: Equatable {
        case letters
        case symbols
    }
    private var keyboardCharacterPage: KeyboardCharacterPage = .letters
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var sizingInputView: VoicePenSizingInputView? { inputView as? VoicePenSizingInputView }
    private var faceContentToBottomBarConstraint: NSLayoutConstraint?
    private var faceContentToViewBottomConstraint: NSLayoutConstraint?
    /// 顶栏的上留白与高度:语音面折叠为 0,字母面恢复 13 / 34。
    private var topBarTopConstraint: NSLayoutConstraint?
    private var topBarHeightConstraint: NSLayoutConstraint?
    /// 面切换键的两套摆位:字母面在顶栏右上,语音面在左下角。
    private var faceSwitchTopBarConstraints: [NSLayoutConstraint] = []
    private var recordingBeganAt: Date?
    private var lastRecordingDuration: TimeInterval = 12
    private var processingBeganAt: Date?
    private var recognitionProgress: CGFloat = 0
    private var currentProcessingStage: DictationProcessingStage?
    private var currentBridgePhase: KeyboardBridgePhase = .idle
    /// 键盘上一次成功交付给宿主的文本(不管是新识别的还是修改后的)。
    /// 修改键的前置校验(§6.3)靠它比对"宿主里紧挨光标的内容仍是这段"。
    private var lastInsertedText: String?
    /// 语音二次修改-执行方略.md v2 §6:是否正处在"已发出 .edit 桥请求,等结果"的窗口。
    /// 为真时 `updateStatus` 对 marked text 的处理要走修改模式分支(见该方法)。
    private var editModeActive = false
    /// 进入修改模式时被标住的原文,仅在 `editModeActive == true` 期间有效。
    /// 错误/超时路径要用它把 marked text 复原,不能凭空清空——那是用户自己的内容。
    private var editBaseText = ""
    /// 最近一次修改交付是否因无法清空宿主输入框而转入剪贴板人工接管。
    private var editReplacementFailed = false
    /// 最近一次同步到的响度包络(0...1),供 `applyVoiceKeyStyle` 构造录音键波形——
    /// 同样的"缓存成实例属性"理由:`updateVoiceButton`/`applyVoiceKeyStyle` 不直接
    /// 接触桥快照,不想为了这一个值改一路方法签名。
    private var currentAudioLevel: Float = 0
    private var lastFeedbackPhase: KeyboardBridgePhase?
    private var keyButtons: [UIButton] = []
    /// 需要「浅色 y1 ink@10% 阴影 / 深色无阴影」的键帽(字母/功能/空格/发送/语音键),
    /// 由 applyKeyboardAppearance() 统一刷新 shadowOpacity。
    private var keycapShadowButtons: [UIButton] = []
    private var voiceEntryHost: UIHostingController<AnyView>?
    private var voiceEditLinkHost: UIHostingController<VoiceEntryLink>?
    private var visibleVoiceButton: UIButton?
    private var bridgeTimer: Timer?
    /// 录音期间专用的波形高频刷新(0.1s),与 `bridgeTimer`(0.5s)分开——那条轮询
    /// 还兼着诊断日志、文字交付一整套工作,不能为了波形流畅一起加速。只在
    /// `.recording` 期间存在,离开就立即失效,不留后台计时器。
    private var levelTimer: Timer?
    private var insertedResetWorkItem: DispatchWorkItem?
    private var lastDirectRequestSentAt: Date?
    /// 直接桥请求发出后多久仍停在 .opening 就判定为"App 未响应(超时)"——
    /// 区别于 App 已接单但报错(.error + errorText)的情形,便于下次设备测试定位真实原因。
    private static let directRequestTimeout: TimeInterval = 3
    /// 诊断日志去噪:只记 phase 变化和一次性的超时,不记每 0.5s 轮询
    private var lastLoggedPhase: KeyboardBridgePhase?
    /// 键盘几何去噪:布局回调里只有数值真的变了才落盘(见 logGeometryIfChanged)
    private var lastLoggedGeometry: KeyboardGeometry?
    /// 回填后的延时采样/重同步,换一次插入就取消上一次,避免叠加
    private var heightAuditWorkItems: [DispatchWorkItem] = []
    /// 内存去噪:轮询里只有占用动了 ≥2MB 才落盘(见 logMemoryIfMoved)
    private var lastLoggedFootprintMB: Double = 0
    /// 词库是否正在后台加载(见 ensureDictionaryLoaded)
    private var isLoadingDictionary = false
    private var didLogOpeningTimeout = false
    private var plainPasteboardFallbackUntil: Date?
    private var plainPasteboardBaselineChangeCount: Int?
    private var isUppercase = false

    // 中文全拼引擎
    private let pinyin = PinyinEngine()
    private var chineseMode = true                 // 默认中文;点「中/英」切换
    private var chineseKeyboardLayout: ChineseKeyboardLayout = .twentySixKey
    private var loadedHotwordVersion: TimeInterval = -1
    private let langButton = KeyFieldButton(type: .system)
    private let layoutButton = KeyFieldButton(type: .system)
    private var t9InputButtons: [UIButton] = []
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private var candidateButtons: [UIButton] = []   // 建满后只换标题,数量恒为 maxVisibleCandidates
    private let keycapPreview = KeycapPreviewView()
    private var keycapRestingBackground: [ObjectIdentifier: UIColor] = [:]
    private var currentKeycapShadowOpacity: Float = 0.40
    private var candidateStackWidthConstraint: NSLayoutConstraint?   // 仅固定槽位模式激活
    private var candidateBarUsesFixedSlots = true
    private var lastCandidateBarWidth: CGFloat = 0
    private var visibleCandidates: [PinyinCandidate] = []  // 实际渲染上屏、按钮 tag 对应的候选
    /// 候选栏只保留一屏常用候选，避免长列表改变点选节奏。
    private static let maxVisibleCandidates = 6
    /// 单帧预算(60fps≈16.7ms);仅当耗时超过一帧才写诊断日志,避免正常敲键刷屏。
    private static let perfLogThresholdMs: Double = 16

    /// 键盘⇄App 实时桥是否可用(付费/已配 App Group 才为真)。
    /// 免费账号为 false:改用 Darwin 通知 + 剪贴板做键盘控制(见下 darwinKb)。
    private var bridgeLive: Bool { AppGroup.isAvailable }
    /// 每个键盘扩展实例的唯一标识。旧实例的 disappear 不能清掉
    /// 新实例已经发布的在线心跳。
    private let keyboardSessionID = UUID().uuidString

    // 免费账号:Darwin 信令观察 + 由事件新鲜度派生的状态
    private let darwinKb = DarwinObserver()
    private var lastAliveAt: Date?
    private var lastRecordingAt: Date?
    private var lastProcessingAt: Date?
    private func fresh(_ t: Date?, _ within: TimeInterval) -> Bool {
        t.map { Date().timeIntervalSince($0) < within } ?? false
    }
    private var isRecordingRemote: Bool { fresh(lastRecordingAt, 1.5) }
    private var isProcessingRemote: Bool { !isRecordingRemote && fresh(lastProcessingAt, 4) }
    private var appAlive: Bool { isRecordingRemote || isProcessingRemote || fresh(lastAliveAt, 2.5) }

#if DEBUG
    /// 视觉回归专用：仅 Debug 构建、且仅在模拟器域显式写入该 key 时生效。
    /// 不绕过真实点击权限，也不进入录音/桥状态机，只让 7c/7d 截图可稳定复现。
    private var quietInkVisualCheckPhase: KeyboardBridgePhase? {
#if QUIET_INK_READY
        return .idle
#elseif QUIET_INK_RECORDING
        return .recording
#elseif QUIET_INK_PROCESSING
        return .processing
#elseif QUIET_INK_FAILED
        return .error
#else
        let markerValue = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            .flatMap { try? String(contentsOf: $0.appendingPathComponent("quiet_ink_visual_phase.txt")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let value = markerValue
            ?? AppGroup.suite?.string(forKey: "QuietInkVisualCheckPhase")
            ?? UserDefaults.standard.string(forKey: "QuietInkVisualCheckPhase")
        switch value {
        case "ready": return .idle
        case "recording": return .recording
        case "processing", "recognizing": return .processing
        case "failed", "error": return .error
        default: return nil
        }
#endif
    }
#endif

    /// 兼容既有桥逻辑的状态出口；状态仍保留给空格键和诊断使用，语音面不再显示文字提示卡。
    private func setSpaceHint(_ text: String) {
        // 语音面不再绘制文字提示区域；保留调用入口以维持录音状态机的时序。
    }

    // MARK: - 实例寿命与内存(2026-08-11,build 127)
    //
    // build 126 的日志翻出了一个此前完全没看见的事实:**键盘扩展在被反复重建**。
    // 15:36–16:10 之间 26 次新实例,其中两次落在 `-→recording` / `-→processing` ——
    // 那两刻用户正举着手机等结果,不可能是他自己收起再唤起键盘。
    //
    // 若重建是被系统杀掉(键盘扩展有硬内存上限,本扩展要吃下 3MB 拼音词库 + SwiftUI),
    // 那么遮挡就有了完整解释:扩展死掉 → 宿主把键盘高度收成 0、输入框落到屏幕最底 →
    // 新实例起来渲染成 277 高 → 宿主没把输入框挪回去 → 键盘正好盖住它。这也解释了
    // "只在语音之后":一次语音录制/整理/回填正是内存峰值所在。
    //
    // 这两行打点把"被杀"和"正常收起"分开:正常收起会先有 `will-disappear`,
    // 被杀则是上一实例毫无告别、直接冒出新实例的 `did-load`。
    private static func memoryText() -> String {
        // os_proc_available_memory():距离本进程被 jetsam 还剩多少字节,扩展里正是关键值。
        let available = Double(os_proc_available_memory()) / 1_048_576
        return String(format: "footprint=%.1fMB avail=%.1fMB", footprintMB(), available)
    }

    private func logMemory(_ reason: String) {
        lastLoggedFootprintMB = Self.footprintMB()
        DiagLog.log("kbMem", "\(reason) \(Self.memoryText())")
    }

    /// 0.5s 轮询里搭车采样,但只有占用真的动了 2MB 以上才落盘——目的是画出
    /// "一次语音前后内存怎么爬"的曲线,不是每半秒写一行。
    private func logMemoryIfMoved() {
        let now = Self.footprintMB()
        guard abs(now - lastLoggedFootprintMB) >= 2 else { return }
        logMemory("poll")
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    deinit {
        DiagLog.log("kbLife", "deinit")
    }

    override func loadView() {
        let input = VoicePenSizingInputView(frame: .zero, inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        input.contentHeight = Self.voiceKeyboardHeight
        self.inputView = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        DiagLog.log("kbLife", "did-load \(Self.memoryText())")
        setupKeyboard()
        (inputView as? VoicePenSizingInputView)?.nearbyKey = { [weak self] point in
            guard let self, self.activeFace != .voice else { return nil }
            func collect(_ view: UIView) -> [KeyFieldButton] {
                if let key = view as? KeyFieldButton { return [key] }
                return view.subviews.flatMap(collect)
            }
            return KeyboardTouchRouting.nearestKey(at: point, in: self.view, keys: collect(self.view))
        }
        (inputView as? VoicePenSizingInputView)?.installTouchSurface()
        applyKeyboardAppearance()
        // 词库**不**在这里加载:默认面是语音面,而语音路径一行都不碰词库。
        // 改为切到字母键盘时按需加载、切回语音面整体卸载,见 ensureDictionaryLoaded()。
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardHeight(currentKeyboardHeight)
        restoreChineseKeyboardLayout()
        applyKeyboardAppearance()
        refreshReturnKeyLabel()   // 新宿主可能要求不同的回车语义
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hostReturnMessageLabel.isHidden = true
        reconnectDocumentID = textDocumentProxy.documentIdentifier
        bindReconnectedDocument()
        publishKeyboardPresence()
        startBridgePolling()
        if !bridgeLive { startDarwinObservers() }
        logGeometry("appear")   // 用户说"刚唤起时正常",这行就是那个正常态的基准值
        logMemory("appear")
        if let target = KeyboardBridgeStore.snapshot().returnTarget {
            let snapshot = KeyboardBridgeStore.snapshot()
            let currentPID = (SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber)?.intValue
            DiagLog.log("hostReturn", "keyboard appeared request=\(snapshot.requestID) pidMatches=\(currentPID == target.pid) documentMatches=\(textDocumentProxy.documentIdentifier == target.documentID)")
        }
        // Production uses the bounded, validated reader; the old broad probe must not
        // swizzle the same factory while the return path is running.
        if hasFullAccess { _ = SWTHostSample() }
        // 新实例起来后再对账一次键盘 frame。build 126 的日志显示每次重建都要经历
        // 0 → 912 → 472 → 277 四段高度,`viewDidAppear` 那一刻还停在 472;若宿主在扩展
        // 被杀那一刻把输入框落到了屏幕底,而后续这串变化它没跟上,输入框就留在键盘底下。
        scheduleHeightAudit(after: 0.5) { [weak self] in
            // iOS 27 Beta 的系统宿主有已报告缺陷(FB24460699):切换后可在
            // 扩展根视图之外增加顶部空白。真机截图为 13pt，而这里的
            // view/input/superview/window/safeArea 仍全是正常值。扩展无权修改那一层；
            // 只在我们自己的几何未收敛时重同步，避免无效抖动进一步干扰宿主。
            self?.resyncKeyboardHeight(reason: "appear")
        }
        if !drainActionKeyboardDelivery() {
            drainPendingText()
        }
        loadHotwordsIfNeeded()   // 语音词典若有更新,同源重注入
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyKeyboardAppearance()
    }

    /// 深浅感知:优先使用扩展实际继承到的 trait。iOS 26 的 Messages 在深色界面仍可能向
    /// 第三方键盘报告 `.light` 的 textDocumentProxy.keyboardAppearance，不能让这个过时值
    /// 覆盖真实界面；只有 trait 未指定时才回退到文本代理。
    private func applyKeyboardAppearance() {
        let dark: Bool
        switch traitCollection.userInterfaceStyle {
        case .dark:
            dark = true
        case .light:
            dark = false
        default:
            dark = textDocumentProxy.keyboardAppearance == .dark
        }
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        // 最底部地球键 / 系统听写键属于 iOS 宿主。扩展自身保持透明，直接透出同一层
        // 系统键盘材质，避免自绘 Quiet Ink 底色与系统控制区形成上下两块色差。
        view.backgroundColor = .clear
        view.isOpaque = false
        inputView?.backgroundColor = .clear
        inputView?.isOpaque = false
        refreshKeycapShadows(dark: dark)
        refreshVoiceActionAppearance(dark: dark)
    }

    /// CALayer 的 shadowColor/borderColor 是静态 CGColor,不会随动态 UIColor 自动重解析,
    /// 键帽阴影浓度必须在这里手动切换。两个值都是从系统键盘截图反解出来的:
    /// 深色 底色 50 / 投影 30 → 黑 @40%;浅色 底色 209 / 投影 137 → 黑 @34%。
    private func refreshKeycapShadows(dark: Bool) {
        let opacity: Float = dark ? 0.40 : 0.34
        currentKeycapShadowOpacity = opacity
        for button in keycapShadowButtons {
            button.layer.shadowOpacity = opacity
        }
    }

    /// 键帽投影必须显式给 shadowPath:UIButton.Configuration 的圆角背景画在子层上,
    /// 不给路径时 CALayer 会按整个矩形边界投影(圆角处漏出直角),而且每帧都要离屏
    /// 计算 alpha 遮罩。显式路径既修形状又省掉离屏渲染。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for button in keycapShadowButtons where button.bounds.width > 0 {
            button.layer.shadowPath = UIBezierPath(
                roundedRect: button.bounds,
                cornerRadius: Self.keycapCornerRadius
            ).cgPath
        }
        // 候选栏的排布判据是实测槽宽,首帧和旋转/换机型时宽度才定下来,这里复算一次。
        // 只在宽度真的变了时才重排——否则 layout → 重排 → layout 会互相触发成死循环。
        let barWidth = candidateScroll.bounds.width
        if barWidth != lastCandidateBarWidth {
            lastCandidateBarWidth = barWidth
            layoutCandidateBar()
        }
        logGeometryIfChanged("layout")
    }

    // MARK: - 键盘高度对账(2026-08-11,§11.1a 的下一步)
    //
    // build 101 按 §11.1a 的两处根因(`allowsSelfSizing` + 999)下药后,2026-08-11 下午
    // 15:40–15:52 在真机上仍**连续多次**复现遮挡,说明那两条不是全部根因。用户同时给出
    // 一条比"概率性"更硬的规律:**只在文字回填进宿主输入框之后才发生**,而且他自己也
    // 分不清"输入框下移了"还是"键盘上移了"。
    //
    // 这里把回填前后的键盘几何逐次落盘,直接回答那个二选一:
    //   viewH   我们渲染的高度(应恒为 keyboardHeight,当前 279)
    //   inputH  系统给 UIInputView 的高度(键盘扩展里 view 通常就是 inputView,两者应相等)
    //   winY/winH  键盘窗口在屏幕坐标里的上沿与高度(**宿主就是照这个上沿摆输入框的**)
    //   screenH 屏幕高度;正常时恒有 winY + winH == screenH
    //
    // 判读:回填前后这组数**一模一样** → 键盘没动,是宿主把输入框放低了(宿主拿到的键盘
    // frame 通知过时/错误,修法在我们这边只能靠 resyncKeyboardHeight 逼它重读);
    // 回填后 viewH/winH 变小或 winY 变大 → 是我们这边的约束在那一轮 layout 里被系统压过去了。
    private struct KeyboardGeometry: Equatable {
        var viewW: CGFloat = -1
        var viewH: CGFloat = -1
        var viewY: CGFloat = -1     // view 在其父视图里的上沿;为负 = 我们的内容顶出了容器
        var inputH: CGFloat = -1
        var supH: CGFloat = -1
        var winY: CGFloat = -1
        var winH: CGFloat = -1
        var screenH: CGFloat = -1
        var selfIsInput = false     // 扩展里 view 常常就是 inputView 本身
        var safeTop: CGFloat = -1
        var safeBottom: CGFloat = -1
        var row = CGRect.zero
        var switchKey = CGRect.zero
        var editKey = CGRect.zero
        var recordKey = CGRect.zero
        var deleteKey = CGRect.zero
        var sendKey = CGRect.zero
        var controlsUnion = CGRect.zero

        var text: String {
            func rect(_ value: CGRect) -> String {
                String(
                    format: "(x%.1f,y%.1f,w%.1f,h%.1f)",
                    value.minX, value.minY, value.width, value.height
                )
            }
            let topPadding = controlsUnion == .zero ? -1 : controlsUnion.minY
            let bottomPadding = controlsUnion == .zero ? -1 : viewH - controlsUnion.maxY
            return String(
                format: "view=%.1fx%.1f viewY=%.1f inputH=%.1f supH=%.1f winY=%.1f winH=%.1f screenH=%.1f gap=%.1f same=%@ safe=%.1f/%.1f row=%@ keys=S%@ E%@ R%@ D%@ X%@ union=%@ padTB=%.1f/%.1f",
                viewW, viewH, viewY, inputH, supH, winY, winH, screenH,
                screenH - (winY + winH), selfIsInput ? "Y" : "N",
                safeTop, safeBottom,
                rect(row), rect(switchKey), rect(editKey), rect(recordKey),
                rect(deleteKey), rect(sendKey), rect(controlsUnion), topPadding, bottomPadding
            )
        }
    }

    private func currentGeometry() -> KeyboardGeometry {
        var g = KeyboardGeometry()
        g.viewW = view.bounds.width
        g.viewH = view.bounds.height
        g.viewY = view.frame.minY
        g.inputH = inputView?.bounds.height ?? -1
        g.supH = view.superview?.bounds.height ?? -1
        g.selfIsInput = inputView === view
        g.safeTop = view.safeAreaInsets.top
        g.safeBottom = view.safeAreaInsets.bottom
        func frameInKeyboard(_ child: UIView?) -> CGRect {
            guard let child, child.superview != nil else { return .zero }
            return child.convert(child.bounds, to: view)
        }
        g.row = frameInKeyboard(voiceControlRow)
        g.switchKey = frameInKeyboard(voiceSwitchButton)
        g.editKey = frameInKeyboard(voiceEditButton)
        g.recordKey = frameInKeyboard(voiceEntryContainer)
        g.deleteKey = frameInKeyboard(voiceDeleteButton)
        g.sendKey = frameInKeyboard(voiceSendButton)
        let visibleKeys = [g.switchKey, g.editKey, g.recordKey, g.deleteKey, g.sendKey]
            .filter { $0.width > 0 && $0.height > 0 }
        g.controlsUnion = visibleKeys.dropFirst().reduce(visibleKeys.first ?? .zero) {
            $0.union($1)
        }
        if let window = view.window {
            g.winH = window.bounds.height
            // UIWindow.convert(_:to: nil) 才是屏幕坐标;view.convert(_:to: nil) 只到窗口坐标。
            g.winY = window.convert(window.bounds, to: nil).minY
            g.screenH = window.windowScene?.screen.bounds.height ?? -1
        }
        return g
    }

    /// 布局回调里每帧都调,只有数值真的变了才写一行——键盘扩展的 CPU/IO 预算不允许逐帧落盘。
    private func logGeometryIfChanged(_ reason: String) {
        let g = currentGeometry()
        guard g != lastLoggedGeometry else { return }
        lastLoggedGeometry = g
        DiagLog.log("kbGeom", "\(reason) \(g.text)")
    }

    /// 无条件写一行:回填前后的定点采样必须成对出现,不能被去重吃掉。
    private func logGeometry(_ reason: String) {
        let g = currentGeometry()
        lastLoggedGeometry = g
        DiagLog.log("kbGeom", "\(reason) \(g.text)")
    }

    /// 回填之后的定点体检:宿主的重排是异步的,单看插入那一瞬间抓不到故障态,
    /// 所以按 0 / 0.3 / 1.2 秒三次采样;中间那次顺手做一次 resync —— 这是本轮真正的
    /// 尝试性修法,把"宿主拿到的键盘 frame 过时"这一支直接堵掉。
    /// 三次采样若数值全等,则本次没能复现/键盘侧没动,结论落在宿主侧。
    private func auditHeightAfterInsertion() {
        heightAuditWorkItems.forEach { $0.cancel() }
        heightAuditWorkItems.removeAll()
        logGeometry("insert-after")
        logMemory("insert-after")
        scheduleHeightAudit(after: 0.3) { [weak self] in
            self?.logGeometry("insert+0.3s")
            self?.resyncKeyboardHeight(reason: "insert")
        }
        scheduleHeightAudit(after: 1.2) { [weak self] in
            self?.logGeometry("insert+1.2s")
            self?.logMemory("insert+1.2s")
        }
    }

    private func scheduleHeightAudit(after delay: TimeInterval, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem(block: body)
        heightAuditWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 键盘高度的唯一写入口：约束决定内部排布，`intrinsicContentSize`
    /// 决定系统对外发布的键盘 frame。两者必须同步，否则系统就可能
    /// 继承上一个 26 键输入法的高度，再用那个高度包住五个语音按键。
    ///
    /// 2026-08-14:语音面与字母面改为各自定高之后,任何写死 `Self.keyboardHeight` 的地方
    /// 都会在语音面上把高度推成字母面的 279——`resyncKeyboardHeight` 当时就是这么错的。
    private var currentKeyboardHeight: CGFloat {
        switch activeFace {
        case .voice:
            return Self.voiceKeyboardHeight
        case .keyboard:
            // 文字键盘保留原有的候选栏、26 键区和底部功能栏总高度；语音面的压缩
            // 不能影响这一面。
            return Self.keyboardHeight
        }
    }


    private func applyKeyboardHeight(_ height: CGFloat) {
        if let constraint = keyboardHeightConstraint,
           abs(constraint.constant - height) >= 0.5 {
            constraint.constant = height
        }
        sizingInputView?.contentHeight = height
        // UIViewController 容器与 UIInputView 自适应是两条尺寸通道。
        // 同步 preferredContentSize，让官方输入法切换所在的宿主容器
        // 也能收到高度变化，不只是扩展内部的 Auto Layout。
        preferredContentSize = CGSize(width: preferredContentSize.width, height: height)
        view.invalidateIntrinsicContentSize()
        inputView?.invalidateIntrinsicContentSize()
    }

    /// 重新申明当前面的固定高度，逼宿主重读键盘 frame。
    ///
    /// 2026-08-14 修两处:
    /// ① **高度取当前面**,不再写死 `Self.keyboardHeight`。此前在语音面上这一推会把 100pt
    ///    的语音面拉成 279pt,直到下一次 0.5 秒桥轮询才被 `updateVoiceHeader` 拽回来——
    ///    用户看到的「切到语音键盘时时不时上下伸展一下」就是它。
    /// ② **不再用 −1pt 抖动制造 frame 变化**。那个旧策略本身会让紧凑语音框
    ///    在状态/输入法切换后短暂变高；现在由固有高度失效通知完成重新声明。
    ///
    /// 判据的选取(2026-08-14 用模拟器实测日志定的,不是照搬注释):
    /// 本文件开头那段注释断言「正常时恒有 `winY + winH == screenH`」——**实测不成立**。
    /// 键盘扩展里 `window.convert(_:to: nil).minY` 恒为 0,健康态下 gap 也恒等于
    /// `screenH - winH`(实测 912 - 100 = 812),拿它当判据等于判据永远为假、永远照推。
    /// 真正可靠的是另外三个数:`viewH`(我们渲染的)、`inputH`(系统给 UIInputView 的)、
    /// `supH`(父容器的)。三者同时等于目标高度,就说明 §11.1a 记的那串
    /// 「0 → 912 → 472 → 277」的重建过程已经收敛,没有什么需要逼宿主重读的。
    private func resyncKeyboardHeight(reason: String) {
        let target = currentKeyboardHeight
        let geometry = currentGeometry()
        let settled = { (value: CGFloat) in abs(value - target) < 0.5 }
        let consistent = settled(geometry.viewH) && settled(geometry.inputH) && settled(geometry.supH)
        guard !consistent else {
            DiagLog.log("kbGeom", "resync-skip(\(reason)) 几何自洽,不推 \(geometry.text)")
            return
        }
        logGeometry("resync-before(\(reason))")
        // 这里只修复扩展自己未收敛的高度。对于根视图之外的 iOS 27
        // 宿主空白，修改此约束既不可见也无法消除，不再做无效的 1pt 抖动。
        UIView.performWithoutAnimation {
            applyKeyboardHeight(target)
            view.superview?.setNeedsLayout()
            view.setNeedsLayout()
            view.superview?.layoutIfNeeded()
            view.layoutIfNeeded()
        }
        logGeometry("resync-after(\(reason))")
    }

    private func refreshVoiceActionAppearance(dark: Bool) {
        for button in [voiceSwitchButton, voiceEditButton, voiceDeleteButton] {
            guard var configuration = button.configuration else { continue }
            configuration.baseBackgroundColor = QuietInkVoiceControlPalette.keycap
            configuration.baseForegroundColor = QuietInkVoiceControlPalette.ink
            button.configuration = configuration
            button.layer.borderWidth = 0
            button.layer.borderColor = UIColor.clear.cgColor
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOffset = CGSize(width: 0, height: 1)
            button.layer.shadowRadius = 0
            // 语音功能键直接沉浸在宿主底色中，不复用字母键的统一投影；否则浅色模式
            // 会在每个功能键周围形成一圈灰色轮廓。
            button.layer.shadowOpacity = 0
        }
        updateVoiceControlButtons()

    }

    /// 动态 UIColor 的 .cgColor 依赖调用时的 UITraitCollection.current,在计时器回调里不可靠;
    /// 这里显式按键盘当前 traitCollection 解析,保证 layer.borderColor 这类原始 CGColor 深浅正确。
    private func resolved(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: view.traitCollection)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keycapPreview.hide()
        hostResolutionTask?.cancel(); hostResolutionTask = nil
        hostOpeningID = nil
        reconnectDocumentID = nil
        DiagLog.log("kbLife", "will-disappear \(Self.memoryText())")
        if bridgeLive {
            KeyboardBridgeStore.clearKeyboardPresence(sessionID: keyboardSessionID)
        }
        bridgeTimer?.invalidate()
        bridgeTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        darwinKb.removeAll()
        heightAuditWorkItems.forEach { $0.cancel() }
        heightAuditWorkItems.removeAll()
    }

    // MARK: - 免费账号 Darwin 语音信令

    private func startDarwinObservers() {
        darwinKb.removeAll()
        darwinKb.observe(DarwinBridge.evtAlive) { [weak self] in self?.lastAliveAt = Date() }
        darwinKb.observe(DarwinBridge.evtRecording) { [weak self] in
            self?.lastRecordingAt = Date(); self?.lastAliveAt = Date(); self?.updateFreeVoiceUI()
        }
        darwinKb.observe(DarwinBridge.evtProcessing) { [weak self] in
            self?.lastProcessingAt = Date(); self?.lastAliveAt = Date(); self?.updateFreeVoiceUI()
        }
        darwinKb.observe(DarwinBridge.evtResult) { [weak self] in
            self?.lastRecordingAt = nil; self?.lastProcessingAt = nil
            self?.drainPendingText(); self?.updateFreeVoiceUI()
        }
        darwinKb.observe(DarwinBridge.evtError) { [weak self] in
            self?.lastRecordingAt = nil; self?.lastProcessingAt = nil
            self?.setSpaceHint("口述失败,重试"); self?.updateFreeVoiceUI()
        }
    }

    /// 免费账号点麦克风/停止的处理。
    private func handleFreeVoiceTap() {
        guard hasFullAccess else { setSpaceHint("请先允许完全访问"); return }
        if isRecordingRemote {
            DarwinBridge.post(DarwinBridge.cmdStop)   // 键盘远程停止
            lastRecordingAt = nil; lastProcessingAt = Date()
            preparePlainPasteboardFallback(duration: 90, requiresChange: true)
            setSpaceHint(Self.hintProcessing)
        } else if isProcessingRemote {
            // 整理中,忽略
        } else if appAlive {
            lastInsertedText = nil
            DarwinBridge.post(DarwinBridge.cmdStart)
            lastRecordingAt = Date()
            preparePlainPasteboardFallback(duration: 90, requiresChange: true)
            setSpaceHint(Self.hintRecording)
        } else {
            setSpaceHint("正在打开 App 录音…")  // App 不在 → 由 Link 覆盖层跳转拉起
        }
        updateFreeVoiceUI()
    }

    /// 由事件新鲜度刷新麦克风键外观、Link 可见性、状态文案。
    private func updateFreeVoiceUI() {
#if DEBUG
        if let phase = quietInkVisualCheckPhase {
            currentBridgePhase = phase
            emitPhaseFeedback(for: phase)
            if phase == .recording {
                recordingBeganAt = recordingBeganAt ?? Date().addingTimeInterval(-7)
                setFace(.voice, animated: activeFace != .voice)
            } else {
                recordingBeganAt = nil
            }
            refreshFaceSwitch()
            voiceEntryHost?.view.isHidden = true
            switch phase {
            case .recording:
                applyVoiceKeyStyle(.recording)
            case .processing:
                applyVoiceKeyStyle(.processing)
            case .error:
                applyVoiceKeyStyle(.failed)
            default:
                applyVoiceKeyStyle(.ready)
            }
            updateVoiceHeader(phase: phase)
            updateSendButtonAppearance(hasContent: phase == .recording)
            return
        }
#endif
        guard !bridgeLive else { return }
        let recording = isRecordingRemote, processing = isProcessingRemote, alive = appAlive
        currentBridgePhase = recording ? .recording : (processing ? .processing : .idle)
        emitPhaseFeedback(for: currentBridgePhase)
        if recording || processing { setFace(.voice, animated: activeFace != .voice) }
        refreshFaceSwitch()
        // App 已存活时不再切换回主 App;直接用 Darwin 控制开始/停止。
        voiceEntryHost?.view.isHidden = recording || processing || alive
        if processing {
            applyVoiceKeyStyle(.processing)
        } else if recording {
            applyVoiceKeyStyle(.recording)
        } else if hasFullAccess && alive {
            applyVoiceKeyStyle(.ready)
        } else {
            applyVoiceKeyStyle(.unauthorized)
        }
        if hasFullAccess {
            if recording { setSpaceHint(Self.hintRecording) }
            else if processing { setSpaceHint(Self.hintProcessing) }
            else { setSpaceHint(Self.hintIdle) }
        } else {
            setSpaceHint("请允许完全访问")
        }
        updateVoiceHeader(phase: currentBridgePhase)
        updateCandidateBarVisibility()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyKeyboardAppearance()   // 切换文本框可能带来不同的 keyboardAppearance
        refreshReturnKeyLabel()     // …以及不同的 returnKeyType(发送 / 搜索 / 换行)
        publishKeyboardPresence()
        if !drainActionKeyboardDelivery() {
            drainPendingText()
        }
    }

    private func setupKeyboard() {
        view.backgroundColor = .clear
        view.isOpaque = false
        // 必须显式打开自适应高度:`UIInputView.allowsSelfSizing` 默认 **false**,那时键盘高度由
        // 系统决定,我们挂在 `view` 上的高度约束只影响内部子视图排布——宿主 App 收到的键盘
        // frame 可能和实际渲染高度对不上,输入框就被盖住。开启后系统才按我们的约束定高,
        // 并把正确高度发给宿主(2026-08-06 微信/Telegram 概率性遮挡的两处根因之一)。
        inputView?.allowsSelfSizing = true
        [topBar, faceContentContainer, bottomBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.backgroundColor = .clear
            $0.isOpaque = false
            view.addSubview($0)
        }
        let keyboardHeightConstraint = view.heightAnchor.constraint(equalToConstant: currentKeyboardHeight)
        // 第二处根因:这条约束原来是 **required(1000)**。系统会往 input view 上挂自己的高度
        // 约束,两条 required 冲突时 Auto Layout 只能断掉其中一条,断哪条不确定——这正是
        // "有一定几率被遮挡"里那个"几率"的来源:某一轮布局里我们的约束被断掉,系统按它自己的
        // 高度把 frame 发给宿主,宿主据此把输入框放到那个位置,下一轮我们的约束又赢回来,
        // 键盘按 277 渲染,于是盖住输入框。降到 999:仍然压得过系统的占位高度,冲突时降级而
        // 不是产生未定义布局。与 `activateGeometry()` 的取舍一致(§11.2 的同一条教训)。
        keyboardHeightConstraint.priority = UILayoutPriority(999)
        self.keyboardHeightConstraint = keyboardHeightConstraint
        let faceContentToBottomBarConstraint = faceContentContainer.bottomAnchor.constraint(
            equalTo: bottomBar.topAnchor,
            constant: -9
        )
        let faceContentToViewBottomConstraint = faceContentContainer.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )
        self.faceContentToBottomBarConstraint = faceContentToBottomBarConstraint
        self.faceContentToViewBottomConstraint = faceContentToViewBottomConstraint
        // 顶栏在语音面整条折叠(高度与上留白都归零),字母面保持原值——候选栏挂在这里,压不得。
        let topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 13)
        let topBarHeightConstraint = topBar.heightAnchor.constraint(equalToConstant: 34)
        self.topBarTopConstraint = topBarTopConstraint
        self.topBarHeightConstraint = topBarHeightConstraint
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topBarTopConstraint,
            topBarHeightConstraint,

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                               constant: Self.keyFieldSideInset),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                constant: -Self.keyFieldSideInset),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                              constant: -Self.bottomBarBottomInset),
            bottomBar.heightAnchor.constraint(equalToConstant: 52),

            faceContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                          constant: Self.keyFieldSideInset),
            faceContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                           constant: -Self.keyFieldSideInset),
            faceContentContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            faceContentToViewBottomConstraint,
            keyboardHeightConstraint
        ])

        // 放大键帽挂在键盘根视图上,且必须在所有键之上;第一排字母的放大头会伸进候选栏那一带,
        // 所以根视图不能裁剪子视图(UIView 默认 clipsToBounds = false,这里显式声明意图)。
        view.clipsToBounds = false
        view.addSubview(keycapPreview)

        buildTopBar()
        buildFaceContent()
        buildBottomBar()
        restoreChineseKeyboardLayout()
        updateSendButtonAppearance(hasContent: false)
        setFace(.voice, animated: false)
        updateCandidateBarVisibility()
    }

    /// 候选栏有两种排布,按"这一批候选能不能整批塞进等宽槽"自动切换:
    ///
    /// **① 固定槽位(默认,绝大多数情况)** —— 整条等分成 `maxVisibleCandidates` 个等宽格,
    /// 第 k 名恒定落在第 k 格。这是用户 2026-08-04 提的规则:候选词一旦出现,除非优先级变了,
    /// 位置就不能相对移动。原实现是 `spacing = 16` 的变宽排列,前面任一候选字数一变
    /// (`ni` 首选「你」→ `niha` 首选「你好」),后面所有候选整体右移一个字宽,落点就错位。
    ///
    /// **② 变宽单行(仅当有长词)** —— 候选栏净宽只有约 329pt(topBar 404 减去右侧 63pt 的
    /// 语音/键盘切换开关和间距),等分后每格约 54.8pt,放不下 4 字以上的词;而词库里 5–8 字的
    /// 词条有 8449 条(最长 8 字)。**"等宽 + 单行 + 不省略"数学上不可兼得**,系统键盘正是
    /// 用变宽绕开这个矛盾的。用户 2026-08-04 拍板:这一批出现放不下的长词时,整条退回变宽单行
    /// (间隙 24pt,与系统实测 23.67~24.33pt 一致),牺牲这一批的位置稳定,换"永不省略"。
    ///
    /// 判定阈值**不写死字数**,而是拿实测槽宽和实测字符串宽度比——换机型/换字号都不会算错。
    private func configureSharedCandidateViews() {
        candidateStack.axis = .horizontal
        candidateStack.alignment = .fill
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        // iOS 26/27 may provide a translucent material behind a custom UIInputView.
        // The candidate row is content, not chrome: leaving it transparent puts the
        // candidate labels under that material and makes them look washed out or
        // completely unreadable. Give this row its own opaque, appearance-aware
        // surface while keeping the rest of the keyboard transparent.
        candidateScroll.backgroundColor = KeyboardTheme.background
        candidateScroll.isOpaque = true
        // Keep this compact text row readable; an opaque background alone does
        // not disable the scroll view's system edge effects on its content.
        if #available(iOS 26.0, *) {
            candidateScroll.topEdgeEffect.isHidden = true
            candidateScroll.bottomEdgeEffect.isHidden = true
            candidateScroll.leftEdgeEffect.isHidden = true
            candidateScroll.rightEdgeEffect.isHidden = true
        }
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        candidateScroll.isHidden = true
        candidateScroll.addSubview(candidateStack)
        // ★ fillEqually 必须有一个确定的总宽才能等分。只钉 contentLayoutGuide 的话宽度由内容
        // 反推,等分退化成"按内容撑开",槽位又会随字数漂移。变宽模式则必须断开这条,
        // 让 stack 按内容定宽、超出时可横向滚动。
        let widthConstraint = candidateStack.widthAnchor.constraint(
            equalTo: candidateScroll.frameLayoutGuide.widthAnchor
        )
        candidateStackWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor)
        ])
        for _ in 0..<Self.maxVisibleCandidates {
            candidateStack.addArrangedSubview(makeCandidateButton())
        }
        applyCandidateBarMode(fixedSlots: true)
    }

    private func makeCandidateButton() -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
        candidateButtons.append(button)
        return button
    }

    /// 候选一律 17pt,不再按字数降字号——降字号是上一版为了硬塞进固定槽而做的妥协,
    /// 它既没能真正避免省略(槽宽被高估成 67pt,实为 54.8pt),又让同一条里字号大小不一。
    private static let candidateFont = UIFont.systemFont(ofSize: 17)
    /// 变宽模式下每个候选左右各留的点击余量。视觉间隙 = spacing(12) + 两侧余量(6+6) = 24pt,
    /// 与系统实测一致;而可点宽度比纯字宽多 12pt。
    private static let candidateLooseInset: CGFloat = 6
    private static let candidateLooseSpacing: CGFloat = 12

    private func applyCandidateBarMode(fixedSlots: Bool) {
        candidateBarUsesFixedSlots = fixedSlots
        candidateStack.distribution = fixedSlots ? .fillEqually : .fill
        candidateStack.spacing = fixedSlots ? 0 : Self.candidateLooseSpacing
        candidateStackWidthConstraint?.isActive = fixedSlots
    }

    private func buildTopBar() {
        topLeftContainer.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topLeftContainer)

        let switchHost = UIHostingController(rootView: makeFaceSwitch())
        addChild(switchHost)
        switchHost.view.backgroundColor = .clear
        switchHost.view.translatesAutoresizingMaskIntoConstraints = false
        // 挂在根视图而不是顶栏:语音面要把它移到左下角,而顶栏在语音面整条折叠成 0 高。
        view.addSubview(switchHost.view)
        switchHost.didMove(toParent: self)
        faceSwitchHost = switchHost

        // 字母面仍在顶栏右上使用 63×34 横向胶囊；语音面的切换键由单行控制行承载。
        faceSwitchTopBarConstraints = [
            switchHost.view.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            // 文字面按 188 版之前的顶栏几何贴合，避免在外层高度切换期间以 centerY
            // 计算出落入第一排字母键的临时位置。
            switchHost.view.topAnchor.constraint(equalTo: topBar.topAnchor),
            switchHost.view.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            switchHost.view.widthAnchor.constraint(
                equalToConstant: QuietInkFaceSwitchControl.capsuleSize.width),
        ]
        NSLayoutConstraint.activate(faceSwitchTopBarConstraints + [
            topLeftContainer.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 2),
            topLeftContainer.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -73),
            topLeftContainer.topAnchor.constraint(equalTo: topBar.topAnchor),
            topLeftContainer.bottomAnchor.constraint(equalTo: topBar.bottomAnchor)
        ])

        buildVoiceHeader()
        buildKeyboardHeader()
    }

    private func buildVoiceHeader() {
        voiceHeaderContent.translatesAutoresizingMaskIntoConstraints = false
        topLeftContainer.addSubview(voiceHeaderContent)

        let statusRow = UIStackView(arrangedSubviews: [
            voiceBrandImageView,
            voiceStatusDot,
            voiceStatusLabel,
            voiceTimerLabel
        ])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        voiceBrandImageView.translatesAutoresizingMaskIntoConstraints = false
        voiceBrandImageView.image = KeyboardTheme.waveformImage()
        voiceBrandImageView.tintColor = KeyboardTheme.ink(alpha: 0.50)
        voiceBrandImageView.contentMode = .scaleAspectFit
        voiceStatusDot.translatesAutoresizingMaskIntoConstraints = false
        voiceStatusDot.layer.cornerRadius = 4.5
        voiceStatusDot.backgroundColor = .clear
        voiceStatusDot.isHidden = true
        voiceSpinnerLayer.frame = CGRect(x: 0, y: 0, width: 9, height: 9)
        voiceSpinnerLayer.path = UIBezierPath(ovalIn: voiceSpinnerLayer.bounds.insetBy(dx: 1, dy: 1)).cgPath
        voiceSpinnerLayer.fillColor = UIColor.clear.cgColor
        voiceSpinnerLayer.strokeColor = resolved(KeyboardTheme.accent).cgColor
        voiceSpinnerLayer.lineWidth = 2
        voiceSpinnerLayer.lineCap = .round
        voiceSpinnerLayer.strokeStart = 0
        voiceSpinnerLayer.strokeEnd = 0.78
        voiceSpinnerLayer.isHidden = true
        voiceStatusDot.layer.addSublayer(voiceSpinnerLayer)
        voiceStatusLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        voiceStatusLabel.textColor = KeyboardTheme.ink(alpha: 0.50)
        voiceStatusLabel.text = Self.voiceBrandName
        voiceTimerLabel.font = .monospacedDigitSystemFont(ofSize: 13.5, weight: .regular)
        voiceTimerLabel.textColor = KeyboardTheme.ink(alpha: 0.30)
        voiceTimerLabel.text = nil
        voiceTimerLabel.isHidden = true
        voiceTimerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        voiceHeaderContent.addSubview(statusRow)

        NSLayoutConstraint.activate([
            voiceHeaderContent.leadingAnchor.constraint(equalTo: topLeftContainer.leadingAnchor),
            voiceHeaderContent.trailingAnchor.constraint(equalTo: topLeftContainer.trailingAnchor),
            voiceHeaderContent.topAnchor.constraint(equalTo: topLeftContainer.topAnchor),
            voiceHeaderContent.bottomAnchor.constraint(equalTo: topLeftContainer.bottomAnchor),
            voiceBrandImageView.widthAnchor.constraint(equalToConstant: 17),
            voiceBrandImageView.heightAnchor.constraint(equalToConstant: 12),
            voiceStatusDot.widthAnchor.constraint(equalToConstant: 9),
            voiceStatusDot.heightAnchor.constraint(equalToConstant: 9),
            statusRow.leadingAnchor.constraint(equalTo: voiceHeaderContent.leadingAnchor),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: voiceHeaderContent.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: voiceHeaderContent.topAnchor),
            statusRow.bottomAnchor.constraint(equalTo: voiceHeaderContent.bottomAnchor)
        ])
    }

    private func buildKeyboardHeader() {
        keyboardHeaderContent.translatesAutoresizingMaskIntoConstraints = false
        topLeftContainer.addSubview(keyboardHeaderContent)
        configureSharedCandidateViews()
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        keyboardHeaderContent.addSubview(candidateScroll)
        NSLayoutConstraint.activate([
            keyboardHeaderContent.leadingAnchor.constraint(equalTo: topLeftContainer.leadingAnchor),
            keyboardHeaderContent.trailingAnchor.constraint(equalTo: topLeftContainer.trailingAnchor),
            keyboardHeaderContent.topAnchor.constraint(equalTo: topLeftContainer.topAnchor),
            keyboardHeaderContent.bottomAnchor.constraint(equalTo: topLeftContainer.bottomAnchor),
            candidateScroll.leadingAnchor.constraint(equalTo: keyboardHeaderContent.leadingAnchor),
            candidateScroll.trailingAnchor.constraint(equalTo: keyboardHeaderContent.trailingAnchor),
            candidateScroll.topAnchor.constraint(equalTo: keyboardHeaderContent.topAnchor),
            candidateScroll.bottomAnchor.constraint(equalTo: keyboardHeaderContent.bottomAnchor)
        ])
    }

    private func buildFaceContent() {
        let voice = UIView()
        let keyboard = UIView()
        voice.translatesAutoresizingMaskIntoConstraints = false
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        faceContentContainer.addSubview(voice)
        faceContentContainer.addSubview(keyboard)
        voiceFaceView = voice
        keyboardFaceView = keyboard

        NSLayoutConstraint.activate([
            voice.leadingAnchor.constraint(equalTo: faceContentContainer.leadingAnchor),
            voice.trailingAnchor.constraint(equalTo: faceContentContainer.trailingAnchor),
            voice.topAnchor.constraint(equalTo: faceContentContainer.topAnchor),
            voice.bottomAnchor.constraint(equalTo: faceContentContainer.bottomAnchor),
            keyboard.leadingAnchor.constraint(equalTo: faceContentContainer.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: faceContentContainer.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: faceContentContainer.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: faceContentContainer.bottomAnchor)
        ])

        // 语音控制键直接沉浸在输入法宿主的底色中，不再额外铺一层面板，避免出现
        // 包住五个按键的黑色/深色框。
        voice.backgroundColor = .clear

        let controlRow = voiceControlRow
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        controlRow.backgroundColor = .clear
        voice.addSubview(controlRow)

        [voiceSwitchButton, voiceEditButton, voiceDeleteButton, voiceSendButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controlRow.addSubview($0)
        }
        configureVoiceControlButton(voiceSwitchButton, symbol: "keyboard", weight: .regular)
        configureVoiceControlButton(voiceEditButton, symbol: "pencil.line", weight: .regular)
        configureVoiceControlButton(voiceDeleteButton, symbol: "delete.left", weight: .regular)
        configureVoiceControlButton(voiceSendButton, symbol: "arrow.turn.down.left", weight: .medium)
        voiceSwitchButton.addTarget(self, action: #selector(voiceSwitchTapped), for: .touchUpInside)
        voiceEditButton.addTarget(self, action: #selector(voiceModifyTapped), for: .touchUpInside)
        voiceDeleteButton.addTarget(self, action: #selector(voiceDeleteBackward), for: .touchUpInside)
        voiceSendButton.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)

        let voiceEntry = makeVoiceEntry()
        voiceEntry.translatesAutoresizingMaskIntoConstraints = false
        controlRow.addSubview(voiceEntry)
        let voiceEditLink = makeVoiceEditLink()
        voiceEditLink.translatesAutoresizingMaskIntoConstraints = false
        controlRow.addSubview(voiceEditLink)

        NSLayoutConstraint.activate([
            controlRow.leadingAnchor.constraint(equalTo: voice.leadingAnchor, constant: Self.voiceInnerInsetX),
            controlRow.trailingAnchor.constraint(equalTo: voice.trailingAnchor, constant: -Self.voiceInnerInsetX),
            // 语音面只保留单行控制键所需高度，并贴住输入法底部，避免上下留下空白。
            controlRow.bottomAnchor.constraint(equalTo: voice.bottomAnchor),
            controlRow.heightAnchor.constraint(equalToConstant: Self.voiceControlAreaHeight),

            voiceSwitchButton.leadingAnchor.constraint(equalTo: controlRow.leadingAnchor),
            voiceEditButton.leadingAnchor.constraint(equalTo: voiceSwitchButton.trailingAnchor, constant: 6),
            voiceEntry.leadingAnchor.constraint(equalTo: voiceEditButton.trailingAnchor, constant: 8),
            voiceEntry.trailingAnchor.constraint(equalTo: voiceDeleteButton.leadingAnchor, constant: -8),
            voiceEntry.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            voiceDeleteButton.trailingAnchor.constraint(equalTo: voiceSendButton.leadingAnchor, constant: -6),
            voiceSendButton.trailingAnchor.constraint(equalTo: controlRow.trailingAnchor),
            voiceEntry.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            voiceEditLink.leadingAnchor.constraint(equalTo: voiceEditButton.leadingAnchor),
            voiceEditLink.trailingAnchor.constraint(equalTo: voiceEditButton.trailingAnchor),
            voiceEditLink.topAnchor.constraint(equalTo: voiceEditButton.topAnchor),
            voiceEditLink.bottomAnchor.constraint(equalTo: voiceEditButton.bottomAnchor)
        ] + [voiceSwitchButton, voiceEditButton, voiceDeleteButton, voiceSendButton].map {
            $0.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor)
        })

        let letters = makeCharacterPageStack()
        let nineKey = makeCharacterPageStack()
        let symbols = makeCharacterPageStack()
        [letters, nineKey, symbols].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            keyboard.addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: keyboard.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: keyboard.trailingAnchor),
                $0.bottomAnchor.constraint(equalTo: keyboard.bottomAnchor, constant: -1)
            ])
        }
        addLetterRows(to: letters)
        addNineKeyRows(to: nineKey)
        addSymbolRows(to: symbols)
        letterKeyboardView = letters
        nineKeyKeyboardView = nineKey
        symbolKeyboardView = symbols
        updateKeyboardCharacterPage(animated: false)
    }

    private func configureVoiceControlButton(
        _ button: UIButton,
        symbol: String,
        weight: UIImage.SymbolWeight
    ) {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = QuietInkVoiceControlPalette.ink
        configuration.baseBackgroundColor = QuietInkVoiceControlPalette.keycap
        configuration.background.cornerRadius = 12
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 21,
            weight: weight
        )
        button.configuration = configuration
        button.layer.cornerRadius = 12
        // 五个控制键直接沉浸在宿主底色中，不绘制额外灰/白边框；按键自身的底色
        // 对比负责区分边界，避免每个键周围出现一圈独立的灰色轮廓。
        button.layer.borderWidth = 0
        button.layer.borderColor = UIColor.clear.cgColor
        button.widthAnchor.constraint(equalToConstant: 46).isActive = true
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.clipsToBounds = false
        registerPressFeedback(for: button, restingBackground: configuration.baseBackgroundColor)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
        button.layer.shadowOpacity = 0
    }

    private func buildBottomBar() {
        configureButton(leftFunctionButton, title: nil, symbol: "globe", style: .utility)
        leftFunctionButton.addTarget(self, action: #selector(leftFunctionTapped), for: .primaryActionTriggered)
        configureButton(sendButton, title: "发送", symbol: nil, style: .utility)
        sendButton.addTarget(self, action: #selector(insertReturn), for: .primaryActionTriggered)
        [leftFunctionButton, bottomMiddleContainer, sendButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            leftFunctionButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            leftFunctionButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            leftFunctionButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            leftFunctionButton.widthAnchor.constraint(equalToConstant: 46),
            sendButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            sendButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            sendButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
            bottomMiddleContainer.leadingAnchor.constraint(equalTo: leftFunctionButton.trailingAnchor, constant: 6),
            bottomMiddleContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            bottomMiddleContainer.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomMiddleContainer.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
        ])

        configureButton(layoutButton, title: "九键", symbol: nil, style: .utility)
        layoutButton.accessibilityIdentifier = "keyboard.layout.toggle"
        layoutButton.addTarget(self, action: #selector(toggleChineseKeyboardLayout), for: .primaryActionTriggered)
        configureButton(langButton, title: nil, symbol: nil, style: .utility)
        langButton.accessibilityIdentifier = "keyboard.language.toggle"
        langButton.addTarget(self, action: #selector(toggleLanguage), for: .primaryActionTriggered)
        configureButton(spaceButton, title: nil, symbol: nil, style: .key)
        spaceButton.accessibilityIdentifier = "keyboard.space"
        spaceButton.addTarget(self, action: #selector(insertSpace), for: .primaryActionTriggered)
        keyboardBottomContent.translatesAutoresizingMaskIntoConstraints = false
        bottomMiddleContainer.addSubview(keyboardBottomContent)
        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        langButton.translatesAutoresizingMaskIntoConstraints = false
        spaceButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardBottomContent.addSubview(layoutButton)
        keyboardBottomContent.addSubview(langButton)
        keyboardBottomContent.addSubview(spaceButton)
        NSLayoutConstraint.activate([
            keyboardBottomContent.leadingAnchor.constraint(equalTo: bottomMiddleContainer.leadingAnchor),
            keyboardBottomContent.trailingAnchor.constraint(equalTo: bottomMiddleContainer.trailingAnchor),
            keyboardBottomContent.topAnchor.constraint(equalTo: bottomMiddleContainer.topAnchor),
            keyboardBottomContent.bottomAnchor.constraint(equalTo: bottomMiddleContainer.bottomAnchor),
            layoutButton.leadingAnchor.constraint(equalTo: keyboardBottomContent.leadingAnchor),
            layoutButton.topAnchor.constraint(equalTo: keyboardBottomContent.topAnchor),
            layoutButton.bottomAnchor.constraint(equalTo: keyboardBottomContent.bottomAnchor),
            layoutButton.widthAnchor.constraint(equalToConstant: 46),
            langButton.leadingAnchor.constraint(equalTo: layoutButton.trailingAnchor, constant: 6),
            langButton.topAnchor.constraint(equalTo: keyboardBottomContent.topAnchor),
            langButton.bottomAnchor.constraint(equalTo: keyboardBottomContent.bottomAnchor),
            langButton.widthAnchor.constraint(equalToConstant: 52),
            spaceButton.leadingAnchor.constraint(equalTo: langButton.trailingAnchor, constant: 6),
            spaceButton.trailingAnchor.constraint(equalTo: keyboardBottomContent.trailingAnchor),
            spaceButton.topAnchor.constraint(equalTo: keyboardBottomContent.topAnchor),
            spaceButton.bottomAnchor.constraint(equalTo: keyboardBottomContent.bottomAnchor)
        ])

        updateLangButton()
        updateLayoutButton()
        updateLeftFunctionButton()
    }

    private func makeFaceSwitch() -> QuietInkFaceSwitchControl {
        QuietInkFaceSwitchControl(
            selection: activeFace,
            isEnabled: currentBridgePhase != .recording && currentBridgePhase != .processing,
            isModifyEnabled: isModifyKeyEnabled,
            onSelect: { [weak self] face in
                self?.setFace(face, animated: true)
            },
            onModify: { [weak self] in
                self?.handleModifyTap()
            }
        )
    }

    /// 修改键的生命周期只由上一段已交付文字决定，不再受 App 心跳 TTL 限制。
    /// App 不在热态时由同位置的 Link 冷启动主 App；有热会话时则直接走桥请求。
    private var isModifyKeyEnabled: Bool {
        hasFullAccess && bridgeLive && !editModeActive
            && currentBridgePhase != .recording && currentBridgePhase != .processing
            && editableInsertedText?.isEmpty == false
    }

    /// 键盘扩展可能在整理期间被系统重建；本地属性丢失时，从 App Group 的已插入结果恢复
    /// 同一修改目标。普通新录音发起时桥快照会清掉 insertedText，因此生命周期正好截止到
    /// 下一段新口述开始。
    private var editableInsertedText: String? {
        if let lastInsertedText, !lastInsertedText.isEmpty { return lastInsertedText }
        let persisted = KeyboardBridgeStore.snapshot().insertedText
        return persisted.isEmpty ? nil : persisted
    }

    /// 修改键点击。**不用 marked text**——实测发现"先删再用 setMarkedText 把刚删掉的
    /// 内容重新标住"这一步,在部分宿主(自绘输入框/网页输入框,如微信这类聊天输入框)上
    /// 不会被当成一段可替换的 marked range,只是普通插入;等最终稿再 setMarkedText 一次
    /// 想"替换"时,宿主根本没有记着"当前标住的是哪一段",于是把新稿插在旁边而不是替换
    /// 掉原文——表现就是原文没删、旁边多出一段新话,这正是实测复现的故障。
    ///
    /// 改为:按修改键只做只读校验,录音/处理期间完全不碰宿主文档(原文原样留在那里,
    /// 舍弃"实时下划线预览"这个锦上添花的效果),真正的替换只在拿到最终结果那一刻
    /// 做一次,用量过再删的确定性 `deleteBackward` + `insertText`(见 `applyEditReplacement`),
    /// 不依赖任何宿主可能不支持的 marked-text 语义。
    private func handleModifyTap() {
        guard isModifyKeyEnabled, let baseText = editableInsertedText, !baseText.isEmpty,
              textDocumentProxy.documentContextBeforeInput?.hasSuffix(baseText) == true else {
            DiagLog.log("edit", "修改键前置校验未通过,不进入修改模式")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        editModeActive = true
        editBaseText = baseText
        refreshFaceSwitch()
        KeyboardBridgeStore.requestEditRecording(baseText: baseText, fieldKind: hostFieldKind,
            target: KeyboardEditTarget(documentID: textDocumentProxy.documentIdentifier,
                hostPID: (SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber)?.intValue,
                before: textDocumentProxy.documentContextBeforeInput ?? "",
                after: textDocumentProxy.documentContextAfterInput))
        lastDirectRequestSentAt = Date()
        setSpaceHint("请说出修改要求")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func voiceSwitchTapped() {
        setFace(activeFace == .voice ? .keyboard : .voice, animated: true)
    }

    @objc private func voiceModifyTapped() {
        handleModifyTap()
    }

    /// 修改模式的最终替换,取代普通路径的 `commitHostMarkedText`(见上方说明,不走
    /// marked text)。`baseText` 由调用方从持久化的桥快照读入,不用本地 `editBaseText`——
    /// 理由同调用点注释。
    ///
    /// 这里只删除 baseText 对应的末尾片段，保留之前的内容；这是“替换目标后插入”的动作:修改结果绝不能在删除失败时退化成普通插入,
    /// 否则就会再次出现“原句保留、新句追加在后面”的老问题。若宿主拒绝删除或无法确认
    /// 当前输入框已经清空,宁可不插入并提示用户重试,也不把修改结果追加到原文后面。
    private func applyEditReplacement(newText: String, baseText: String) {
        editReplacementFailed = false
        defer {
            editModeActive = false
            refreshFaceSwitch()
            KeyboardBridgeStore.clearEditBaseText()
        }
        guard !newText.isEmpty else {
            DiagLog.log("edit", "最终替换结果为空,不清空输入框,不插入")
            return
        }

        guard let target = KeyboardBridgeStore.snapshot().editTarget else {
            reportEditReplacementFailure(newText: newText, reason: "缺少原输入框信息，未执行替换")
            return
        }
        let outcome = KeyboardEditReplacement.perform(target: target, baseText: baseText, replacement: newText,
            read: {
                let proxy = self.textDocumentProxy
                return KeyboardEditContext(documentID: proxy.documentIdentifier,
                    hostPID: (SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber)?.intValue,
                    before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                    hasText: proxy.hasText)
            },
            deleteBackward: { self.textDocumentProxy.deleteBackward() },
            insert: { replacement in self.textDocumentProxy.insertText(replacement) })
        switch outcome {
        case .inserted(let deletions):
            DiagLog.log("edit", "替换已发出：删除 \(deletions) 次，新稿 \(newText.count) 字")
        case .failed(let reason, let deletions):
            reportEditReplacementFailure(newText: newText, reason: "\(reason)，删除 \(deletions) 次")
        }
    }

    /// 清空失败时把原始整理稿交给用户手动完成替换。这里仅写入剪贴板,不读取剪贴板,
    /// 避免触发普通输入过程的隐私读取；错误反馈让用户知道这次没有自动插入。
    private func reportEditReplacementFailure(newText: String, reason: String) {
        editReplacementFailed = true
        UIPasteboard.general.items = [["public.utf8-plain-text": newText]]
        DiagLog.log("edit", "\(reason),新稿已复制到剪贴板")
        setSpaceHint("修改失败,新稿已复制")
        showHostReturnMessage("修改失败，新稿已复制，请手动粘贴")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func refreshFaceSwitch() {
        faceSwitchHost?.rootView = makeFaceSwitch()
        updateVoiceControlButtons()
    }

    private func updateVoiceControlButtons() {
        guard voiceSwitchButton.configuration != nil else { return }
        if var switchConfiguration = voiceSwitchButton.configuration {
            let targetFace = activeFace == .voice ? "keyboard" : "waveform"
            switchConfiguration.image = UIImage(systemName: targetFace)
            switchConfiguration.baseBackgroundColor = QuietInkVoiceControlPalette.keycap
            switchConfiguration.baseForegroundColor = QuietInkVoiceControlPalette.ink
            voiceSwitchButton.configuration = switchConfiguration
            voiceSwitchButton.accessibilityLabel = activeFace == .voice ? "切换到键盘模式" : "切换到语音模式"
        }

        if var editConfiguration = voiceEditButton.configuration {
            let enabled = isModifyKeyEnabled
            editConfiguration.baseBackgroundColor = enabled
                ? QuietInkVoiceControlPalette.accent
                : QuietInkVoiceControlPalette.keycapDisabled
            editConfiguration.baseForegroundColor = enabled
                ? QuietInkVoiceControlPalette.onAccent
                : QuietInkVoiceControlPalette.inkDisabled
            voiceEditButton.configuration = editConfiguration
            voiceEditButton.isEnabled = enabled
            voiceEditButton.accessibilityLabel = enabled ? "修改录音" : "修改录音，不可用"
            keycapRestingBackground[ObjectIdentifier(voiceEditButton)] = editConfiguration.baseBackgroundColor
        }
        let editCanUseColdPath = isModifyKeyEnabled && !KeyboardBridgeStore.canAcceptDirectKeyboardRequest()
        voiceEditLinkHost?.view.isHidden = !editCanUseColdPath
    }

    /// 录音期间波形的高频驱动。只在这一路走 0.1s——`bridgeTimer`(0.5s)那条轮询
    /// 还兼着诊断日志、文字交付一整套工作,不能为了波形流畅一起加速。
    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshLevelTicks()
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    /// 只重建 `voiceCapsuleHost` 的 rootView,不经过 `applyVoiceKeyStyle`——那个函数
    /// 还会重启"呼吸点"CABasicAnimation(`updateRecordingAnimations`),0.1s 调一次
    /// 会让那个动画永远播不完一个周期,看起来是断的。
    private func refreshLevelTicks() {
        guard case .recording = lastVoiceKeyState else { stopLevelTimer(); return }
        currentAudioLevel = KeyboardBridgeStore.snapshot().audioLevel ?? 0
        voiceCapsuleHost?.rootView = QuietInkVoiceControlRecordButton(
            state: .recording(clock: recordingClockText), audioLevel: currentAudioLevel)
    }

    private func setFace(_ face: QuietInkKeyboardFace, animated: Bool) {
        let busy = currentBridgePhase == .recording || currentBridgePhase == .processing
        guard !busy || face == .voice else { return }
        activeFace = face
        let voiceSelected = face == .voice
        // 词库跟着面板走:切到字母面才加载,切回语音面整体卸载(§11.1d)。
        if voiceSelected {
            unloadDictionary(reason: "切到语音面")
        } else {
            restoreChineseKeyboardLayout()
            if chineseMode { ensureDictionaryLoaded() }
        }
        updateLetterKeysEnabled()
        if voiceSelected {
            faceContentToBottomBarConstraint?.isActive = false
            faceContentToViewBottomConstraint?.isActive = true
        } else {
            faceContentToViewBottomConstraint?.isActive = false
            faceContentToBottomBarConstraint?.isActive = true
        }
        // 语音面压到 voiceKeyboardHeight:顶栏整条折叠；单行五键的面切换键由语音控制行承载。
        // activeFace 已在上面赋值,currentKeyboardHeight 即为切换后的目标高度。
        applyKeyboardHeight(currentKeyboardHeight)
        topBarTopConstraint?.constant = voiceSelected ? 0 : 13
        topBarHeightConstraint?.constant = voiceSelected ? 0 : 34
        NSLayoutConstraint.deactivate(faceSwitchTopBarConstraints)
        if !voiceSelected {
            NSLayoutConstraint.activate(faceSwitchTopBarConstraints)
        }
        faceSwitchHost?.view.isHidden = voiceSelected
        keyboardFaceView?.clipsToBounds = false
        keyboardFaceView?.isHidden = voiceSelected
        voiceFaceView?.isHidden = !voiceSelected
        if !voiceSelected {
            bottomBar.isHidden = false
        }
        // UIInputView 在语音面从 66pt 切回文字面时可能暂存旧 frame；明确要求宿主和
        // 扩展同步重新布局，确保 279pt 文字面包含完整三排字母键。
        view.invalidateIntrinsicContentSize()
        inputView?.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.superview?.setNeedsLayout()
        view.superview?.layoutIfNeeded()
        view.layoutIfNeeded()
        let changes = {
            self.voiceFaceView?.alpha = voiceSelected ? 1 : 0
            self.voiceFaceView?.transform = voiceSelected ? .identity : CGAffineTransform(scaleX: 0.98, y: 0.98)
            self.keyboardFaceView?.alpha = voiceSelected ? 0 : 1
            self.keyboardFaceView?.transform = voiceSelected ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            self.voiceHeaderContent.alpha = voiceSelected ? 1 : 0
            self.keyboardHeaderContent.alpha = voiceSelected ? 0 : 1
            self.bottomBar.alpha = voiceSelected ? 0 : 1
            self.view.superview?.layoutIfNeeded()
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: changes
            ) { _ in
                self.bottomBar.isHidden = voiceSelected
                self.view.superview?.setNeedsLayout()
                self.view.superview?.layoutIfNeeded()
                self.view.layoutIfNeeded()
            }
        } else {
            changes()
            bottomBar.isHidden = voiceSelected
        }
        voiceFaceView?.isUserInteractionEnabled = voiceSelected
        keyboardFaceView?.isUserInteractionEnabled = !voiceSelected
        updateLeftFunctionButton()
        refreshFaceSwitch()
        updateCandidateBarVisibility()
    }

    @objc private func leftFunctionTapped() {
        if keyboardCharacterPage == .letters {
            commitBestCandidateIfNeeded()
        }
        keyboardCharacterPage = keyboardCharacterPage == .letters ? .symbols : .letters
        updateKeyboardCharacterPage(animated: true)
    }

    private func updateLeftFunctionButton() {
        guard var configuration = leftFunctionButton.configuration else { return }
        configuration.image = nil
        configuration.title = keyboardCharacterPage == .letters ? "123" : "ABC"
        leftFunctionButton.accessibilityLabel = keyboardCharacterPage == .letters
            ? "切换到数字和符号"
            : "返回字母键盘"
        leftFunctionButton.configuration = configuration
    }

    private func restoreChineseKeyboardLayout() {
        let saved = SharedKeyboardPreferenceStore.selectedLayout
        guard saved != chineseKeyboardLayout else {
            pinyin.setInputMode(saved == .nineKey ? .nineKey : .twentySixKey)
            updateLayoutButton()
            return
        }
        if pinyin.isComposing { commitBestCandidateIfNeeded() }
        chineseKeyboardLayout = saved
        pinyin.setInputMode(saved == .nineKey ? .nineKey : .twentySixKey)
        updateKeyboardCharacterPage(animated: false)
        updateLayoutButton()
    }

    @objc private func toggleChineseKeyboardLayout() {
        guard chineseMode else { return }
        if pinyin.isComposing { commitBestCandidateIfNeeded() }
        chineseKeyboardLayout = chineseKeyboardLayout == .twentySixKey ? .nineKey : .twentySixKey
        SharedKeyboardPreferenceStore.selectedLayout = chineseKeyboardLayout
        pinyin.setInputMode(chineseKeyboardLayout == .nineKey ? .nineKey : .twentySixKey)
        isUppercase = false
        keyboardCharacterPage = .letters
        updateKeyboardCharacterPage(animated: true)
        updateLayoutButton()
        updateLetterKeysEnabled()
        refreshCandidateBar()
    }

    private func updateLayoutButton() {
        guard var configuration = layoutButton.configuration else { return }
        let targetIsNineKey = chineseKeyboardLayout == .twentySixKey
        configuration.title = targetIsNineKey ? "九键" : "26键"
        configuration.baseForegroundColor = KeyboardTheme.ink(alpha: chineseMode ? 1 : 0.40)
        layoutButton.configuration = configuration
        layoutButton.isEnabled = chineseMode
        layoutButton.accessibilityLabel = targetIsNineKey
            ? "切换到九宫格拼音"
            : "切换到二十六键拼音"
    }

    /// 52pt 录音键 + 透明 SwiftUI Link 覆盖。
    /// ★冷启动跳转依赖此 Link 覆盖层物理压在录音键之上；录音键热区向四周外扩，
    /// 但视觉布局仍严格只占 52pt，避免点击间距被浪费。
    private func makeVoiceEntry() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        voiceEntryContainer = container
        // 宽度由外层拉伸(删除键与发送键之间的整段),这里只定高。
        container.heightAnchor.constraint(
            equalToConstant: QuietInkVoiceControlRecordButton.height).isActive = true

        let capsuleHost = UIHostingController(
            rootView: QuietInkVoiceControlRecordButton(
                state: hasFullAccess ? .idle : .unavailable,
                audioLevel: currentAudioLevel
            )
        )
        addChild(capsuleHost)
        capsuleHost.view.backgroundColor = .clear
        capsuleHost.view.isUserInteractionEnabled = false
        // 录音键的可点击热区为视觉尺寸左右各外扩 8pt、上下各外扩 4pt。
        capsuleHost.view.clipsToBounds = false
        capsuleHost.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(capsuleHost.view)
        capsuleHost.didMove(toParent: self)
        voiceCapsuleHost = capsuleHost

        let visualButton = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        visualButton.configuration = config
        visualButton.backgroundColor = .clear
        visualButton.accessibilityIdentifier = "voice.record"
        visualButton.addTarget(self, action: #selector(voiceEntryTapped), for: .touchUpInside)
        visualButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(visualButton)
        visibleVoiceButton = visualButton
        applyVoiceKeyStyle(hasFullAccess ? .ready : .unauthorized)

        let entry = AnyView(Button(action: { [weak self] in
            self?.beginColdVoiceEntry()
        }) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("开始 Shall We Talk 口述"))
        let host = UIHostingController(rootView: entry)
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        host.didMove(toParent: self)
        voiceEntryHost = host

        hostReturnMessageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hostReturnMessageLabel.textAlignment = .center
        hostReturnMessageLabel.numberOfLines = 2
        hostReturnMessageLabel.textColor = .label
        hostReturnMessageLabel.backgroundColor = .secondarySystemBackground
        hostReturnMessageLabel.layer.cornerRadius = 15
        hostReturnMessageLabel.clipsToBounds = true
        hostReturnMessageLabel.isUserInteractionEnabled = false
        hostReturnMessageLabel.isHidden = true
        hostReturnMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostReturnMessageLabel)
        NSLayoutConstraint.activate([
            hostReturnMessageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostReturnMessageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostReturnMessageLabel.topAnchor.constraint(equalTo: container.topAnchor),
            hostReturnMessageLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        NSLayoutConstraint.activate([
            capsuleHost.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            capsuleHost.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            capsuleHost.view.topAnchor.constraint(equalTo: container.topAnchor),
            capsuleHost.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            visualButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -8),
            visualButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 8),
            visualButton.topAnchor.constraint(equalTo: container.topAnchor, constant: -4),
            visualButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 4),
            host.view.leadingAnchor.constraint(equalTo: visualButton.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: visualButton.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: visualButton.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: visualButton.bottomAnchor),
        ])

        return container
    }

    /// App 不在热态时，修改键通过 Link 先把主 App 拉到前台；点击手势先把原文和修改意图
    /// 写入 App Group，主 App 收到 `voicepen://edit` 后即可沿用同一套修改录音状态机。
    private func showHostReturnMessage(_ message: String) {
        hostReturnMessageLabel.text = message
        hostReturnMessageLabel.isHidden = false
        visibleVoiceButton?.accessibilityLabel = message
    }

    private func beginColdVoiceEntry() {
        guard hasFullAccess else { showHostReturnMessage("请先允许完全访问"); return }
        guard hostOpeningID == nil else { return }
        if !bridgeLive {
            preparePlainPasteboardFallback(duration: 90, requiresChange: true)
            SWTOpenHostURL(VoicePenURL.record) { _ in }
            return
        }
        let operation = UUID()
        hostOpeningID = operation
        let document = textDocumentProxy.documentIdentifier
        guard let pid = SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber, pid.intValue > 0 else {
            hostOpeningID = nil; showHostReturnMessage("未能识别当前 App，请重试"); return
        }
        if Self.hostMapping?.pid != pid.intValue { Self.hostMapping = nil }
        showHostReturnMessage("正在准备录音…")
        hostResolutionTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self, !Task.isCancelled, self.hostOpeningID == operation else { return }
                guard self.textDocumentProxy.documentIdentifier == document,
                      (SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber)?.intValue == pid.intValue else {
                    self.hostOpeningID = nil; self.showHostReturnMessage("输入位置已改变，请重新开始"); return
                }
                let sample = SWTHostSample()
                let now = Date().timeIntervalSince1970
                var target: HostReturnTarget?
                if let observedPID = sample["pid"] as? NSNumber, observedPID.intValue == pid.intValue,
                   let bundle = sample["bundle"] as? String, let at = sample["at"] as? Double {
                    let fresh = HostReturnTarget(pid: pid.intValue, bundleID: bundle, observedAt: at, documentID: document)
                    if fresh.isValid(now: now) {
                        if let old = Self.hostMapping, old.isValid(now: now), old.bundleID != bundle {
                            Self.hostMapping = nil; self.hostOpeningID = nil
                            self.showHostReturnMessage("App 身份变化，请重新开始"); return
                        }
                        Self.hostMapping = fresh
                        target = fresh
                    }
                }
                if target == nil, let cached = Self.hostMapping, cached.isValid(now: now) {
                    target = HostReturnTarget(pid: cached.pid, bundleID: cached.bundleID,
                                              observedAt: cached.observedAt, documentID: document)
                }
                if let target {
                    self.lastInsertedText = nil
                    self.reconnectDocumentID = nil
                    let requestID = KeyboardBridgeStore.requestRecording(fieldKind: self.hostFieldKind, returnTarget: target)
                    DiagLog.log("hostReturn", "prepare request=\(requestID) pid=\(target.pid) bundle=\(target.bundleID) age=\(now-target.observedAt)")
                    let url = URL(string: "voicepen://record?request=\(requestID)")!
                    self.openColdURL(url, operation: operation)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, self.hostOpeningID == operation else { return }
            self.hostOpeningID = nil; Self.hostMapping = nil
            self.showHostReturnMessage("未能识别当前 App，请重试")
        }
    }

    private func openColdURL(_ url: URL, operation: UUID) {
        let finish: (Bool) -> Void = { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, self.hostOpeningID == operation else { return }
                self.hostOpeningID = nil
                self.showHostReturnMessage(accepted ? "正在打开 Shall We Talk…" : "未能打开 App，请重试")
            }
        }
        extensionContext?.open(url) { [weak self] accepted in
            DispatchQueue.main.async {
                guard self?.hostOpeningID == operation else { return }
                if accepted { finish(true) } else { SWTOpenHostURL(url, finish) }
            }
        }
        if extensionContext == nil { SWTOpenHostURL(url, finish) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.hostOpeningID == operation else { return }
            self.hostOpeningID = nil; self.showHostReturnMessage("打开超时，请重试")
        }
    }

    private func makeVoiceEditLink() -> UIView {
        let link = VoiceEntryLink(destination: VoicePenURL.edit, onTap: { [weak self] in
            self?.handleModifyTap()
        }, label: "修改上一段录音")
        let host = UIHostingController(rootView: link)
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.didMove(toParent: self)
        voiceEditLinkHost = host
        host.view.isHidden = true
        return host.view
    }

    private func startBridgePolling() {
        bridgeTimer?.invalidate()
        pollBridge()
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollBridge()
        }
        if let bridgeTimer {
            RunLoop.main.add(bridgeTimer, forMode: .common)
        }
    }

    @objc private func voiceEntryTapped() {
        hostReturnMessageLabel.isHidden = true
        guard hasFullAccess else {
            setSpaceHint("请先允许完全访问")
            DiagLog.log("tap", "麦克风点击被拒:无完全访问")
            return
        }
        // 免费账号:Darwin 控制(续录/停止);App 不在时由 Link 覆盖层跳转拉起
        if !bridgeLive {
            DiagLog.log("tap", "免费模式点击(Darwin 路径)recording=\(isRecordingRemote) alive=\(appAlive)")
            handleFreeVoiceTap()
            return
        }
        let snapshot = KeyboardBridgeStore.snapshot()
        let effectivePhase = KeyboardBridgeStore.effectivePhase(snapshot)
        let heartbeatAge = snapshot.appHeartbeatAt > 0
            ? String(format: "%.1fs", Date().timeIntervalSince1970 - snapshot.appHeartbeatAt) : "无"
        let shouldStop = effectivePhase == .recording
        if effectivePhase == .processing {
            setSpaceHint(Self.hintProcessing)
            DiagLog.log("tap", "点击忽略:App 整理中")
            return
        }
        let canSendDirectly = shouldStop || KeyboardBridgeStore.canAcceptDirectKeyboardRequest()
        // 完整决策快照:点按落在按钮上(Link 覆盖层此时必隐藏),走桥请求分支
        DiagLog.log("tap", "按钮点击 phase=\(snapshot.phase.rawValue) 心跳=\(heartbeatAge) needsFG=\(snapshot.needsForeground) 直发=\(canSendDirectly) 分支=\(shouldStop ? "停止" : "开始")")
        if shouldStop {
            KeyboardBridgeStore.requestStopRecording()
        } else {
            lastInsertedText = nil
            KeyboardBridgeStore.requestRecording(fieldKind: hostFieldKind)
        }
        if canSendDirectly {
            lastDirectRequestSentAt = Date()
            didLogOpeningTimeout = false
        }
        setSpaceHint(shouldStop ? Self.hintRecording : (canSendDirectly ? Self.hintIdle : "正在打开 Shall We Talk…"))
    }

    private func bindReconnectedDocument() {
        guard let document = reconnectDocumentID,
              document == textDocumentProxy.documentIdentifier,
              let pid = SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber,
              KeyboardBridgeStore.snapshot().returnedDocumentID == nil else { return }
        KeyboardBridgeStore.bindReturnedDocument(document, hostPID: pid.intValue)
    }

    private func pollBridge() {
        bindReconnectedDocument()
        logMemoryIfMoved()
#if DEBUG
        if quietInkVisualCheckPhase != nil {
            updateFreeVoiceUI()
            return
        }
#endif
        // 免费账号:走 Darwin 信令驱动的本地状态 + 剪贴板取结果。
        guard bridgeLive else {
            updateFreeVoiceUI()
            drainPendingText()
            return
        }
        publishKeyboardPresence()
        let snapshot = KeyboardBridgeStore.snapshot()
        var effectiveSnapshot = snapshot
        effectiveSnapshot.phase = KeyboardBridgeStore.effectivePhase(snapshot)
        let appAwake = KeyboardBridgeStore.isAppAwake()
        let canSendDirectly = KeyboardBridgeStore.canAcceptDirectKeyboardRequest()
        currentAudioLevel = effectiveSnapshot.phase == .recording ? (snapshot.audioLevel ?? 0) : 0
        let directStopAvailable = effectiveSnapshot.phase == .recording || effectiveSnapshot.phase == .processing
        let directRequestInFlight = lastDirectRequestSentAt.map { Date().timeIntervalSince($0) < 2 } ?? false
        // 诊断:只记 phase 变化(不记每 0.5s 轮询);错误相包含 App 发布的具体错误文案
        if snapshot.phase != lastLoggedPhase {
            let extra = snapshot.phase == .error ? " needsFG=\(snapshot.needsForeground) err=\(snapshot.errorText)" : ""
            DiagLog.log("poll", "桥状态 \(lastLoggedPhase?.rawValue ?? "-")→\(snapshot.phase.rawValue) 直发=\(canSendDirectly)\(extra)")
            lastLoggedPhase = snapshot.phase
        }
        // 诊断:直发请求超时只记一次(App 未接单,大概率进程被挂起)
        if snapshot.phase == .opening, !didLogOpeningTimeout,
           let sentAt = lastDirectRequestSentAt, Date().timeIntervalSince(sentAt) > Self.directRequestTimeout {
            didLogOpeningTimeout = true
            DiagLog.log("poll", "直发请求超时(>\(Int(Self.directRequestTimeout))s 仍 opening):App 未响应,判定被挂起")
        }
        // App 明确回报"此刻无法后台起录,需要切前台"时,不管心跳多新鲜都要重新露出跳转 Link——
        // 否则用户会一直卡在按钮上收到死的失败文案,却无法触发真正能成功的前台路径。
        let needsForegroundJump = snapshot.phase == .error && snapshot.needsForeground
        // App 刚有心跳、能直接收桥请求时也隐藏 Link,让点击落到下方按钮走 voiceEntryTapped 的
        // 直接请求分支,避免"App 已醒着却仍跳转切 App"。
        voiceEntryHost?.view.isHidden = !needsForegroundJump
            && (directStopAvailable || directRequestInFlight || canSendDirectly)
        updateVoiceButton(isAppAwake: appAwake,
                          canSendDirectly: directStopAvailable || directRequestInFlight || canSendDirectly,
                          phase: effectiveSnapshot.phase)
        updateStatus(from: effectiveSnapshot,
                     appAwake: appAwake,
                     canSendDirectly: canSendDirectly)
        // 本轮状态显示与文字投递必须使用同一份快照。否则 App 恰好在
        // updateStatus() 与 drainPendingText() 之间发布 ready 时，会出现
        // “界面仍是 processing、文字却已插入”的裂脑状态。
        if !drainActionKeyboardDelivery() {
            drainPendingText(expectedRequestID: snapshot.resultRequestID)
        }
    }

    private enum VoiceKeyState {
        case ready
        case recording
        case processing
        case inserted
        case failed
        case indirect
        case unauthorized
    }

    /// ① 未就绪的状态行/提示文字要跟着圆键走,而圆键的可用性判定在免费与付费两条路径里
    /// 各算各的;这里存下最后一次实际应用的态,updateVoiceHeader 直接读,不重复那套判定。
    private var lastVoiceKeyState: VoiceKeyState = .unauthorized

    /// 录音计时文本。设计稿把计时放进录音卡片内部,不再由顶部状态行承担。
    private var recordingClockText: String {
        let elapsed = Int(Date().timeIntervalSince(recordingBeganAt ?? Date()))
        return String(format: "%d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60)
    }

    private func applyVoiceKeyStyle(_ state: VoiceKeyState) {
        lastVoiceKeyState = state
        let capsuleState: QuietInkVoiceControlRecordState
        switch state {
        case .ready:
            capsuleState = .idle
        case .recording:
            capsuleState = .recording(clock: recordingClockText)
        case .processing:
            capsuleState = .processing
        case .inserted:
            capsuleState = .idle
        case .failed, .indirect:
            capsuleState = .idle
        case .unauthorized:
            capsuleState = .unavailable
        }
        // 插入确认沿用录音键的 ready 几何，避免单行控制区因状态切换发生位移。
        if state == .inserted {
            voiceCapsuleHost?.rootView = QuietInkVoiceControlRecordButton(
                state: .idle, audioLevel: currentAudioLevel)
        } else {
            voiceCapsuleHost?.rootView = QuietInkVoiceControlRecordButton(
                state: capsuleState, audioLevel: currentAudioLevel)
        }
        visibleVoiceButton?.isEnabled = state != .processing
        let recording = state == .recording
        // 删除宿主输入框与录音、网络和完整访问权限无关，任何语音状态都保持同一外观且可用。
        voiceDeleteButton.isEnabled = true
        voiceDeleteButton.alpha = 1
        updateVoiceControlButtons()
        updateRecordingAnimations(active: recording)
    }

    private func updateVoiceButton(isAppAwake: Bool, canSendDirectly: Bool, phase: KeyboardBridgePhase) {
        switch phase {
        case .recording:
            applyVoiceKeyStyle(.recording)
        case .processing:
            applyVoiceKeyStyle(.processing)
        case .inserted:
            // Rendering a persisted result must never replay its success haptic.
            applyVoiceKeyStyle(.ready)
        case .error:
            applyVoiceKeyStyle(.failed)
        case .ready:
            applyVoiceKeyStyle(.ready)
        default:
            applyVoiceKeyStyle(canSendDirectly ? .ready : (isAppAwake ? .indirect : .unauthorized))
        }
        if phase == .processing {
            visibleVoiceButton?.accessibilityLabel = "正在处理，录音暂不可用"
        } else {
            visibleVoiceButton?.accessibilityLabel = phase == .recording ? "停止录音" : "开始录音"
        }
    }

    private func showInsertedConfirmation() {
        insertedResetWorkItem?.cancel()
        applyVoiceKeyStyle(.inserted)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentBridgePhase != .recording,
                  self.currentBridgePhase != .processing else { return }
            self.applyVoiceKeyStyle(self.hasFullAccess ? .ready : .unauthorized)
        }
        insertedResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: item)
    }

    private func emitPhaseFeedback(for phase: KeyboardBridgePhase) {
        guard phase != lastFeedbackPhase else { return }
        let hadPreviousPhase = lastFeedbackPhase != nil
        lastFeedbackPhase = phase
        guard hadPreviousPhase, phase != .inserted else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateStatus(from snapshot: KeyboardBridgeSnapshot, appAwake: Bool, canSendDirectly: Bool) {
        guard hasFullAccess else {
            setSpaceHint("请允许完全访问")
            return
        }

        // 出口 1:空格键提示文案(空闲/录音/整理/错误)。
        let effectivePhase: KeyboardBridgePhase = snapshot.insertedText.isEmpty ? snapshot.phase : .inserted
        currentBridgePhase = effectivePhase
        emitPhaseFeedback(for: effectivePhase)
        currentProcessingStage = effectivePhase == .processing ? snapshot.processingStage : nil
        if effectivePhase == .recording || effectivePhase == .processing {
            setFace(.voice, animated: activeFace != .voice)
        }
        if effectivePhase == .recording {
            startLevelTimer()
        } else {
            stopLevelTimer()
        }
        refreshFaceSwitch()
        switch effectivePhase {
        case .idle:
            // 桥请求半路"蒸发"回 idle(App 被杀、从未真正起录)而不是走 .error 时的
            // 同一条安全网:不能让 editModeActive 卡死在 true,永久锁住修改键。修改模式
            // 在拿到最终结果前完全不碰宿主文档(见 handleModifyTap),这里不需要复原什么,
            // 只清状态。持久化的 editBaseText 无条件清一次(不看本地 editModeActive——
            // 键盘进程可能已经重建过,本地状态未必反映真实情况),避免残留值污染下一次
            // 普通口述的交付判断。
            if editModeActive {
                editModeActive = false
                refreshFaceSwitch()
            }
            KeyboardBridgeStore.clearEditBaseText()
            setSpaceHint(Self.hintIdle)
        case .opening:
            // 直接请求发出后长时间仍是 .opening = App 从未接单(大概率被系统挂起、0.5s 轮询没跑),
            // 与"App 接单后报错"要分开显示,否则设备测试反馈不出真实原因。
            if let sentAt = lastDirectRequestSentAt, Date().timeIntervalSince(sentAt) > Self.directRequestTimeout {
                setSpaceHint("App 未响应(超时)")
            } else {
                setSpaceHint(appAwake ? "正在启动口述" : "正在打开 Shall We Talk…")
            }
        case .recording:
            setSpaceHint(editModeActive ? "请说出修改要求" : Self.hintRecording)
        case .processing:
            setSpaceHint(editModeActive ? "正在修改…"
                        : (snapshot.processingStage == .recognizing ? Self.hintRecognizing : Self.hintProcessing))
        case .ready:
            setSpaceHint(Self.hintIdle)
        case .inserted:
            setSpaceHint(Self.hintIdle)
        case .error:
            // 修改模式的原文这时还完全没被动过(见 handleModifyTap),不需要复原,
            // 只清状态、把修改键重新点亮;persisted editBaseText 同 .idle 分支的理由,
            // 无条件清一次。
            if editModeActive {
                editModeActive = false
                refreshFaceSwitch()
            }
            KeyboardBridgeStore.clearEditBaseText()
            // needsForeground = App 已接单但判定此刻无法后台起录(非偶发错误),
            // Link 已重新露出,提示用户再点一下即可跳转前台真正开始。
            if snapshot.needsForeground {
                setSpaceHint("点击跳转录音")
            } else {
                setSpaceHint(snapshot.errorText.isEmpty ? "口述失败,重试" : snapshot.errorText)
            }
        }

        // Only the finalized cleanup result may write into the host document.
        // Live ASR remains in the bridge; unmarking it would commit an unwanted draft.
        updateVoiceHeader(phase: effectivePhase)
        updateSendButtonAppearance(hasContent: !snapshot.insertedText.isEmpty || !snapshot.liveText.isEmpty)
        updateCandidateBarVisibility()
    }

    /// Apply punctuation/spacing only to the final cleaned text at the current cursor.
    private func boundaryAdjusted(_ text: String) -> String {
        InsertionBoundary.adjust(
            text: text,
            before: textDocumentProxy.documentContextBeforeInput,
            after: textDocumentProxy.documentContextAfterInput,
            capitalizeSentenceStart: textDocumentProxy.autocapitalizationType == .sentences)
    }

    private func updateVoiceHeader(phase: KeyboardBridgePhase) {
        let recording = phase == .recording
        let processing = phase == .processing
        let failed = phase == .error
        if recording, recordingBeganAt == nil { recordingBeganAt = Date() }
        if !recording, let began = recordingBeganAt {
            lastRecordingDuration = max(1, Date().timeIntervalSince(began))
            recordingBeganAt = nil
        }
        updateRecognitionProgress(processing: processing, failed: failed)
        // 高度归 setFace 统一裁决(语音面与字母面不同高),这里不能再无条件写回 keyboardHeight,
        // 否则语音面每刷新一次状态就被顶回 279。
        applyKeyboardHeight(currentKeyboardHeight)

        // ① 未就绪:圆键是空心态且并非缺完整访问权限,状态行改灰点 +「正在唤醒麦克风」。
        let notReady = !recording && !processing && !failed
            && lastVoiceKeyState == .unauthorized && hasFullAccess

        voiceBrandImageView.isHidden = recording || processing || failed || notReady
        voiceStatusDot.isHidden = !(recording || processing || failed || notReady)
        voiceTimerLabel.isHidden = !(recording || processing)

        if recording {
            voiceSpinnerLayer.isHidden = true
            voiceStatusDot.layer.cornerRadius = 4.5
            voiceStatusDot.layer.borderWidth = 0
            voiceStatusDot.backgroundColor = KeyboardTheme.recordingRed
            voiceStatusDot.layer.shadowColor = resolved(KeyboardTheme.recordingRed.withAlphaComponent(0.18)).cgColor
            voiceStatusDot.layer.shadowRadius = 3.5
            voiceStatusDot.layer.shadowOpacity = 1
            voiceStatusLabel.text = "正在聆听"
            voiceStatusLabel.textColor = KeyboardTheme.ink
        } else if processing {
            voiceSpinnerLayer.isHidden = false
            voiceStatusDot.layer.cornerRadius = 4.5
            voiceStatusDot.backgroundColor = .clear
            voiceStatusDot.layer.borderWidth = 0
            voiceSpinnerLayer.strokeColor = resolved(KeyboardTheme.accent).cgColor
            voiceStatusDot.layer.shadowOpacity = 0
            voiceStatusLabel.text = "正在整理"
            voiceStatusLabel.textColor = KeyboardTheme.ink(alpha: 0.55)
        } else if failed {
            voiceSpinnerLayer.isHidden = true
            voiceStatusDot.layer.cornerRadius = 4.5
            voiceStatusDot.backgroundColor = KeyboardTheme.recordingRed
            voiceStatusDot.layer.borderWidth = 0
            voiceStatusDot.layer.shadowOpacity = 0
            voiceStatusLabel.text = "识别失败 · 点一下重试"
            voiceStatusLabel.textColor = KeyboardTheme.recordingRed
        } else if notReady {
            voiceSpinnerLayer.isHidden = true
            voiceStatusDot.layer.cornerRadius = 4.5
            voiceStatusDot.layer.borderWidth = 0
            voiceStatusDot.backgroundColor = KeyboardTheme.ink(alpha: 0.30)
            voiceStatusDot.layer.shadowOpacity = 0
            voiceStatusLabel.text = "正在唤醒麦克风"
            voiceStatusLabel.textColor = KeyboardTheme.ink(alpha: 0.50)
        } else {
            voiceSpinnerLayer.isHidden = true
            voiceStatusDot.layer.borderWidth = 0
            voiceStatusDot.backgroundColor = .clear
            voiceStatusDot.layer.shadowOpacity = 0
            voiceStatusLabel.text = Self.voiceBrandName
            voiceStatusLabel.textColor = KeyboardTheme.ink(alpha: 0.50)
        }

        #if DEBUG
        if quietInkVisualCheckPhase == .recording {
            voiceTimerLabel.text = "0:07"
        } else if quietInkVisualCheckPhase == .processing {
            voiceTimerLabel.text = "68%"
        } else if let began = recordingBeganAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(began)))
            voiceTimerLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        } else if processing {
            voiceTimerLabel.text = "\(Int((recognitionProgress * 100).rounded()))%"
        } else {
            voiceTimerLabel.text = nil
        }
        #else
        if let began = recordingBeganAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(began)))
            voiceTimerLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        } else if processing {
            voiceTimerLabel.text = "\(Int((recognitionProgress * 100).rounded()))%"
        } else {
            voiceTimerLabel.text = nil
        }
        #endif
        voiceTimerLabel.textColor = KeyboardTheme.ink(alpha: recording ? 0.40 : 0.30)

        updateRecordingAnimations(active: recording)
    }

    private func updateRecognitionProgress(processing: Bool, failed: Bool) {
        if processing {
            if processingBeganAt == nil {
                processingBeganAt = Date()
                recognitionProgress = 0.12
            }
#if DEBUG
            if quietInkVisualCheckPhase == .processing {
                recognitionProgress = 0.68
            } else {
                advanceRecognitionProgress()
            }
#else
            advanceRecognitionProgress()
#endif
            voiceCapsuleHost?.rootView = QuietInkVoiceControlRecordButton(state: .processing)
            return
        }

        if failed {
            processingBeganAt = nil
            recognitionProgress = 0
            return
        }

        if processingBeganAt != nil {
            processingBeganAt = nil
            recognitionProgress = 1
        } else {
            recognitionProgress = 0
        }
    }

    private func advanceRecognitionProgress() {
        guard let began = processingBeganAt else { return }
        let elapsed = Date().timeIntervalSince(began)
        if currentProcessingStage == .cleaning {
            recognitionProgress = min(0.97, max(0.90, recognitionProgress + 0.006))
        } else {
            let expectedDuration = max(3, lastRecordingDuration)
            let mapped = 0.12 + CGFloat(elapsed / expectedDuration) * 0.78
            recognitionProgress = min(0.90, max(recognitionProgress, mapped))
        }
    }

    private func updateRecordingAnimations(active: Bool) {
        voiceStatusDot.layer.removeAnimation(forKey: "quietInkRecordingPulse")
        voiceSpinnerLayer.removeAnimation(forKey: "quietInkRecognizingSpin")
        voiceStatusDot.layer.opacity = 1
        voiceStatusDot.layer.transform = CATransform3DIdentity
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        if active {
            let dotPulse = CABasicAnimation(keyPath: "opacity")
            dotPulse.fromValue = 1
            dotPulse.toValue = 0.35
            dotPulse.duration = 1
            dotPulse.autoreverses = true
            dotPulse.repeatCount = .infinity
            voiceStatusDot.layer.add(dotPulse, forKey: "quietInkRecordingPulse")
        } else if currentBridgePhase == .processing {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 0.9
            spin.repeatCount = .infinity
            voiceSpinnerLayer.add(spin, forKey: "quietInkRecognizingSpin")
        }
    }

    /// 发送键:有待插入内容(用 bridge snapshot 的 insertedText/liveText 非空作为信号)时点亮
    /// accent 实心 + 白字 semibold;否则恢复功能键灰。仅由 updateStatus()(付费桥路径)驱动——
    /// 免费/Darwin 模式没有干净的"待插入内容"信号,保守地不接线,发送键保持默认功能键灰。
    /// 宿主通过 `returnKeyType` 声明这颗键该叫什么。系统键盘就是照它标字的,我们跟着标,
    /// 键面才不会说谎。
    ///
    /// **为什么必须这么做**:键盘扩展**没有任何 API 能触发宿主的"发送"动作**——
    /// `UITextDocumentProxy` 只给了 insertText / deleteBackward / adjustTextPosition,
    /// 到底算发送还是换行,完全由宿主自己解释那个 `\n`。iMessage 把它当发送;WhatsApp、
    /// Telegram 的输入框本来就是多行、发送是 App 内那颗独立按钮,于是只换行(系统键盘在
    /// 这两个 App 里同样只换行)。既然做不到真发送,至少别把"换行"画成"发送"
    /// (2026-08-06 用户反馈:发送键只在 iMessage 里能发)。
    private var hostReturnKeyLabel: (title: String, symbol: String) {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send:      return ("发送", "arrow.up")
        case .go:        return ("前往", "arrow.right")
        case .search:    return ("搜索", "magnifyingglass")
        case .google, .yahoo: return ("搜索", "magnifyingglass")
        case .done:      return ("完成", "checkmark")
        case .next:      return ("下一项", "arrow.right")
        case .continue:  return ("继续", "arrow.right")
        case .join, .route, .emergencyCall:
            return ("换行", "return")
        case .default:   return ("换行", "return")
        @unknown default: return ("换行", "return")
        }
    }

    /// 当前输入框的语义,交给主 App 决定这次口述怎么整理(见 `HostFieldKind`)。
    ///
    /// 与 `hostReturnKeyLabel` 读同一份 `UITextInputTraits`,只是用途不同:那边决定键面
    /// 写什么字,这边决定整理走哪条路由。`keyboardType` 优先于 `returnKeyType`——邮箱框
    /// 的回车键也可能是"前往",但它首先是个邮箱框,整理无论如何都只会添乱。
    ///
    /// 密码框(`isSecureTextEntry`)按 2026-08-14 的决定不做特殊处理,与普通文本框同路。
    private var hostFieldKind: HostFieldKind {
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress, .URL, .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation,
             .asciiCapableNumberPad:
            return .restricted
        default:
            break
        }
        switch textDocumentProxy.returnKeyType ?? .default {
        case .search, .google, .yahoo: return .search
        case .send:                    return .messaging
        default:                       return .general
        }
    }

    /// 换宿主/换输入框时要按新的 `returnKeyType` 重标键面,但那些时机拿不到 hasContent,
    /// 这里记住上一次的值供重刷使用。
    private var lastSendButtonHasContent = false

    /// 切到别的 App 或别的输入框后重标发送/换行键。`returnKeyType` 是随输入框走的,
    /// 同一个 App 里(如搜索框 vs 聊天框)也会变。
    private func refreshReturnKeyLabel() {
        updateSendButtonAppearance(hasContent: lastSendButtonHasContent)
    }

    private func updateSendButtonAppearance(hasContent: Bool) {
        lastSendButtonHasContent = hasContent
        guard var config = sendButton.configuration else { return }
        let label = hostReturnKeyLabel
        config.title = label.title
        config.baseBackgroundColor = hasContent ? KeyboardTheme.accent : KeyboardTheme.functionKey
        config.baseForegroundColor = hasContent ? KeyboardTheme.voiceGlyph : KeyboardTheme.keyLabel
        sendButton.configuration = config
        // ★ 发送键是唯一一个静息底色会动态变(accent ↔ 功能键灰)的键。按下反馈抬手时要按
        // "静息色"还原,这张表不同步的话,点一次亮着的发送键就会把 accent 抹成灰。
        keycapRestingBackground[ObjectIdentifier(sendButton)] = config.baseBackgroundColor
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: hasContent ? .semibold : .regular)

        if var voiceConfiguration = voiceSendButton.configuration {
            let voiceCanSend = currentBridgePhase == .recording || hasContent
            // 语音面只有图标没有文字,同样跟着宿主的声明换:宿主要发送就给上箭头,
            // 只换行就给回车符号,不再一律画成 arrow.right(那个看着像"发送")。
            voiceConfiguration.image = UIImage(systemName: label.symbol)
            // 输出键是唯一实心强调键；无内容时回到 disabled keycap，但位置与热区不变。
            voiceConfiguration.baseBackgroundColor = voiceCanSend
                ? QuietInkVoiceControlPalette.accent
                : QuietInkVoiceControlPalette.keycapDisabled
            voiceConfiguration.baseForegroundColor = voiceCanSend
                ? QuietInkVoiceControlPalette.onAccent
                : QuietInkVoiceControlPalette.inkDisabled
            voiceSendButton.configuration = voiceConfiguration
            voiceSendButton.isEnabled = voiceCanSend
            voiceSendButton.alpha = 1
            keycapRestingBackground[ObjectIdentifier(voiceSendButton)] = voiceConfiguration.baseBackgroundColor
            voiceSendButton.layer.borderWidth = 0
            voiceSendButton.layer.borderColor = UIColor.clear.cgColor
            voiceSendButton.layer.shadowOpacity = 0
        }
    }

    private enum ButtonStyle {
        case key, utility, space
    }

    /// 键帽视觉规格全部来自对系统键盘截图的逐像素取样(iPhone Air 420pt / iOS 26.5 / 深色,
    /// 见 工程规划.md §11「键帽视觉基准」)。改这里的任何常数前请先重测,不要凭手感调。
    private static let keycapCornerRadius: CGFloat = 5     // 原 9,过圆会把 36×45 的键帽视觉缩小
    private static let keycapTitleSize: CGFloat = 25       // 原 23;实测系统 x-height 13pt → 25pt
    private static let utilityTitleSize: CGFloat = 16      // "123"/"发送" 实测字高 11.67pt
    private static let utilitySymbolSize: CGFloat = 20     // shift/delete 字形实测 21×18pt

    private func configureButton(_ button: UIButton, title: String?, symbol: String?, style: ButtonStyle) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = symbol.map { UIImage(systemName: $0) } ?? nil
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        config.cornerStyle = .fixed
        config.background.cornerRadius = Self.keycapCornerRadius
        switch style {
        case .key:
            config.baseForegroundColor = KeyboardTheme.keyLabel
            config.baseBackgroundColor = KeyboardTheme.letterKey
        case .utility:
            // 系统键盘的功能键字形与字母键一样是纯白/纯黑,不降透明度——降了就是本轮要修的
            // "识别度不足"本身。
            config.baseForegroundColor = KeyboardTheme.keyLabel
            config.baseBackgroundColor = KeyboardTheme.functionKey
        case .space:
            config.baseForegroundColor = KeyboardTheme.ink(alpha: 0.38)
            config.baseBackgroundColor = KeyboardTheme.spaceIdle
        }
        if symbol != nil, style == .utility {
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: Self.utilitySymbolSize,
                weight: .regular
            )
        }
        button.configuration = config
        button.titleLabel?.font = .systemFont(ofSize: style == .key ? Self.keycapTitleSize
                                                                    : Self.utilityTitleSize,
                                             weight: .regular)
        // 按下反馈:字母键弹放大键帽,功能键换底色。两者都挂在 .touchDown 上——手指落下即响应,
        // 不等抬手。这是"手感快"的主要来源,和后台算得多快无关。
        registerPressFeedback(for: button, restingBackground: config.baseBackgroundColor)
        // 不在按钮上单独钉高度——letter 行高 45、底排行高 44 各由所在 row 的
        // heightAnchor 决定,UIStackView 默认 .fill 对齐会把按钮撑到 row 高度,避免两处高度约束打架。
        //
        // 键帽投影:系统键盘在深浅两种模式下都有一条 1pt 硬投影(实测深色下键帽正下方
        // 3px = RGB 30 压在 RGB 50 的底色上 → 黑色 @40%)。原实现把 shadowColor 设成 ink,
        // 深色下 ink 近白、只能整条关掉,键帽因此彻底失去下边界。
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
        button.layer.shadowOpacity = 0   // 由 refreshKeycapShadows() 按当前浅深模式设置
        keycapShadowButtons.append(button)
    }

    // MARK: - 按下反馈(2026-08-04,纯视觉、无声)
    //
    // 用户要求"按 iPhone 自带键盘的方式反馈,但不要声音"。系统的做法分两种:
    //   · 字母 / 符号键 —— 向上弹出放大键帽(KeycapPreviewView)
    //   · 功能键(shift/删除/123/中英/发送/空格)—— 底色与字母键色对调
    // 两者都绑在 `.touchDown`(以及 `.touchDragEnter`)上,手指落下的那一帧就有反馈。
    // 文字键通过 primaryActionTriggered 在触摸落下时提交；这里的事件只管理外观。

    /// 按下时的底色:功能键↔字母键对调(系统做法);accent 之类的自定义底色则压暗。
    private func pressedBackground(forResting color: UIColor?) -> UIColor? {
        guard let color else { return nil }
        if color === KeyboardTheme.functionKey { return KeyboardTheme.letterKey }
        if color === KeyboardTheme.letterKey { return KeyboardTheme.functionKey }
        return color.withAlphaComponent(0.72)
    }

    private func registerPressFeedback(for button: UIButton, restingBackground: UIColor?) {
        keycapRestingBackground[ObjectIdentifier(button)] = restingBackground
        button.addTarget(self, action: #selector(keyPressBegan(_:)),
                         for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(keyPressEnded(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func keyPressBegan(_ sender: UIButton) {
        if let title = previewTitle(for: sender) {
            keycapPreview.show(
                title: title,
                over: sender,
                in: view,
                cornerRadius: Self.keycapCornerRadius,
                fill: KeyboardTheme.letterKey,
                text: KeyboardTheme.keyLabel,
                shadowOpacity: currentKeycapShadowOpacity
            )
        }
        guard var configuration = sender.configuration,
              let pressed = pressedBackground(forResting: keycapRestingBackground[ObjectIdentifier(sender)])
        else { return }
        configuration.baseBackgroundColor = pressed
        sender.configuration = configuration
    }

    @objc private func keyPressEnded(_ sender: UIButton) {
        keycapPreview.hide(for: sender)
        guard var configuration = sender.configuration,
              let resting = keycapRestingBackground[ObjectIdentifier(sender)] else { return }
        configuration.baseBackgroundColor = resting
        sender.configuration = configuration
    }

    /// 只有字母 / 符号键弹放大键帽。空格没有标题、功能键的标题是 "123"/"发送" 这类词——
    /// 系统对这些键也不弹,所以这里靠"在 keyButtons 里"来判定,而不是靠有没有标题。
    private func previewTitle(for button: UIButton) -> String? {
        guard keyButtons.contains(button), let value = button.accessibilityIdentifier else { return nil }
        let title = displayValue(for: value)
        return title.isEmpty ? nil : title
    }

    // MARK: - 字母键几何(2026-07-13 对齐 iOS 系统键盘竖屏布局,消除误触)
    //
    // 三排字母键统一使用同一 key 宽度 k,由第 1 排(q–p,10 键,贴 sideInset 排满)反推:
    //   k = (Wc − 9×hGap) / 10   其中 Wc = 该行自身 widthAnchor(= stack 宽度,两侧已扣掉 keyFieldSideInset)
    // 用 widthAnchor(multiplier:constant:) 表达成 Wc 的线性函数,交给 Auto Layout 联立求解——
    // 无论设备宽度多少,10×k + 9×hGap 恒等于 Wc,不会有像素误差导致的挤压/溢出。
    // MARK: - 键盘总高与底部留白(2026-08-03 下移收窄)
    //
    // 键盘扩展的 view 贴屏幕底部,iOS 26 会在它下方再画一条系统的 globe/听写行。
    // 原来底栏距 view 底留 20pt,叠加系统行后视觉空档明显,整块键盘"浮"得太高。
    // 减小总高等价于把整块键盘向下平移同样的距离:这里同时把总高与底部留白各减 14,
    // 于是 bottomBar.top = keyboardHeight − bottomBarBottomInset − 52 保持不变(当时为 219),
    // **字母区相对底栏的排布一个像素都不动**,只是整体下移 14pt、总高小 14pt。
    // 语音面板隐藏底栏、直接铺到 view 底,共用同一个 keyboardHeight,因此自动等比缩小,
    // 两个面板的面积始终一致(2026-08-03 用户要求)。
    //
    // **2026-08-13 iOS 27 跟随 +2pt**:iPhone Air 模拟器 26.5 / 27.0 同配置 A/B 实测
    // (深色、中文拼音 26 键、`AppleKeyboards` 只留拼音+emoji),系统键盘的**字母区几何
    // 一字未变**(键高 45 / 行距 11 / 键隙 6 / shift 1.35k / 居中留白 27 全部逐像素相同),
    // 唯一变化是系统键盘总高 346 → 348pt:整块键区相对屏幕底部**上移 2pt**,而最底下那条
    // globe/听写行的图标位置绝对不动(两版都是距屏幕底 26.67pt、x 29.00–386.67pt)。
    // 这里照抄同一个位移:keyboardHeight 277 → 279,其余常量一律不动。效果与系统一致——
    // bottomBar 仍贴 view 底 6pt(相对屏幕底不动),字母区随 view 顶上移 2pt,
    // faceContentContainer 只是在底部多出 2pt 余量,**键位几何仍然一个像素不动**。
    // 侧留白(keyFieldSideInset = 4)在本轮**刻意不动**:模拟器两版都稳定量到 6.67pt,
    // 但 26.5 与 27.0 之间没有差异,所以那是"真机 vs 模拟器 / 原测量口径"的既有出入,
    // 不是 iOS 27 的变化,只能等真机截图复核,不该借这轮改动顺手改窄键宽。
    /// 语音面板左上角显示的品牌名。2026-08-03 由内部设计代号「静墨 / Quiet Ink」
    /// 改为 App 的正式名称——「静墨」是视觉体系的名字,不是产品名,不该出现在用户界面上。
    private static let voiceBrandName = "Shall We Talk"

    private static let keyboardHeight: CGFloat = 279        // 291 → 277(2026-08-03)→ 279(iOS 27 跟随 +2pt)
    private static let bottomBarBottomInset: CGFloat = 6    // 原 20

    /// 语音面只容纳底部单行控制键；文字面仍单独使用 keyboardHeight 的完整高度。
    private static let voiceKeyboardHeight: CGFloat = 66
    /// 单行五键方案的控制行间距。
    private static let voiceRowGap: CGFloat = 8
    private static let voiceControlAreaHeight: CGFloat = 66

    /// 语音面内容相对**键盘视图**的左右留白 = 面板外边距 6 + 面板 padding 10 = 16。
    ///
    /// 字母面用的是 `keyFieldSideInset`(4,贴边排三排键),两者口径不同,不能混用——
    /// 混用正是「按键太靠边、左右不对称」的来源(2026-08-14 用户指出)。
    private static let voiceContentInsetX: CGFloat = 16
    /// `voice` 容器本身已经被 `faceContentContainer` 内缩了 keyFieldSideInset,
    /// 容器内的元素只需再补这一段就能凑够 voiceContentInsetX。
    private static var voiceInnerInsetX: CGFloat { voiceContentInsetX - keyFieldSideInset }


    /// 键区左右贴边留白。系统键盘实测:第 1 排首键左缘 4.00pt、末键右缘 416.00pt(420pt 机型),
    /// 因此 W = 412 → k = (412 − 9×6)/10 = 35.8pt,与实测键宽 35.67~36.00pt 吻合。
    /// 原值 8 给出 k = 35.0pt,键窄了 0.8pt——叠加 9pt 圆角与低对比度键色,就是"按键看起来更小"。
    /// bottomBar 必须同步,否则底排会比上面三排各缩进 4pt,左右边缘出现台阶。
    private static let keyFieldSideInset: CGFloat = 4

    private static let hGap: CGFloat = 6
    /// 用户提供的 iOS 标准键盘截图中，三排键帽高度均为 135px(@3x)=45pt，
    /// 相邻行起点相差 168px(@3x)=56pt，因此净排间距为 11pt。
    private static let letterKeyHeight: CGFloat = 45
    private static let letterRowSpacing: CGFloat = 11
    private static let keyWidthMultiplier: CGFloat = 0.1        // 1/10
    private static let keyWidthConstant: CGFloat = -5.4         // -(9×hGap)/10
    /// 第 2 排(a–l,9 键)左右各留的居中留白 = (Wc − (9k + 8×hGap)) / 2,化简为 Wc 的线性表达。
    private static let row2SpacerMultiplier: CGFloat = 0.05
    private static let row2SpacerConstant: CGFloat = 0.3
    /// 第 3 排 shift/删除键宽 = 1.35k;z–m 7 键与第 1/2 排同宽度 k 且居中,
    /// shift/删除与字母区之间的留白 = 居中留白 − 侧键宽。
    ///
    /// 2026-08-04:1.25k 改 1.35k。系统键盘实测 shift/删除 = 48.33pt、侧留白 = 14.33pt,
    /// 而 1.25k 只有 44.75pt、侧留白 17.75pt——侧键偏窄、离字母区偏远,是 shift/删除误触的来源。
    /// 1.35k = 0.135·W − 7.29;侧留白由恒等式 2s + 2g + 7k + 6·hGap = W 解出 = 0.015·W + 8.19。
    private static let sideKeyWidthMultiplier: CGFloat = 0.135  // 1.35/10
    private static let sideKeyWidthConstant: CGFloat = -7.29    // -1.35×(9×hGap)/10
    private static let row3GapMultiplier: CGFloat = 0.015
    private static let row3GapConstant: CGFloat = 8.19

    /// 防御性激活:优先级 999(而非 required)。各行宽度公式虽为恒等式,但与 UIStackView
    /// 内部 required 约束联立时,浮点残差或系统给的异常容器尺寸都可能触发"不可满足约束";
    /// required 冲突最坏可抛异常砸掉扩展进程,999 只降级为断开该条并打日志,键盘绝不因此崩。
    private func activateGeometry(_ constraint: NSLayoutConstraint) {
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
    }

    /// 用 KeyFieldStackView 而不是普通 UIStackView:键与键之间的缝上的触摸要改判给最近的键
    /// (见该类注释——"漏点"是拼不出音节的主要来源)。
    private func makeCharacterPageStack() -> UIStackView {
        let stack = KeyFieldStackView()
        stack.axis = .vertical
        stack.spacing = Self.letterRowSpacing
        stack.distribution = .fill
        return stack
    }

    private func addLetterRows(to stack: UIStackView) {
        let row1 = makeTopLetterRow()
        stack.addArrangedSubview(row1)

        let row2 = makeMiddleLetterRow()
        stack.addArrangedSubview(row2)
        stack.setCustomSpacing(Self.letterRowSpacing, after: row1)

        let row3 = makeBottomLetterRow()
        stack.addArrangedSubview(row3)
        stack.setCustomSpacing(Self.letterRowSpacing, after: row2)
    }

    /// 九宫格与 26 键共用三行 45pt + 两段 11pt 的竖向几何，因此不改变键盘总高度。
    /// 每行固定为三个输入格和一个操作格；420pt 机型单格约 98.5pt，触摸面积充足。
    private func addNineKeyRows(to stack: UIStackView) {
        let rows: [[(title: String, identifier: String, action: Selector, isUtility: Bool)]] = [
            [
                ("@ / .", "t9.punctuation", #selector(insertT9Punctuation), false),
                ("ABC\n2", "t9.2", #selector(insertT9Key(_:)), false),
                ("DEF\n3", "t9.3", #selector(insertT9Key(_:)), false),
                ("", "t9.delete", #selector(deleteBackward), true)
            ],
            [
                ("GHI\n4", "t9.4", #selector(insertT9Key(_:)), false),
                ("JKL\n5", "t9.5", #selector(insertT9Key(_:)), false),
                ("MNO\n6", "t9.6", #selector(insertT9Key(_:)), false),
                ("清空", "t9.clear", #selector(clearT9Composition), true)
            ],
            [
                ("PQRS\n7", "t9.7", #selector(insertT9Key(_:)), false),
                ("TUV\n8", "t9.8", #selector(insertT9Key(_:)), false),
                ("WXYZ\n9", "t9.9", #selector(insertT9Key(_:)), false),
                ("分词", "t9.separator", #selector(insertT9Separator), true)
            ]
        ]

        for (rowIndex, specs) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Self.hGap
            row.distribution = .fillEqually
            activateGeometry(row.heightAnchor.constraint(equalToConstant: Self.letterKeyHeight))
            for spec in specs {
                let button = KeyFieldButton(type: .system)
                let symbol = spec.identifier == "t9.delete" ? "delete.left" : nil
                configureButton(button,
                                title: symbol == nil ? spec.title : nil,
                                symbol: symbol,
                                style: spec.isUtility ? .utility : .key)
                button.accessibilityIdentifier = spec.identifier
                button.accessibilityLabel = t9AccessibilityLabel(for: spec.identifier, title: spec.title)
                button.titleLabel?.numberOfLines = 2
                button.titleLabel?.textAlignment = .center
                button.addTarget(self, action: spec.action, for: .primaryActionTriggered)
                row.addArrangedSubview(button)
                if spec.identifier.hasPrefix("t9."),
                   spec.identifier.last?.isNumber == true {
                    t9InputButtons.append(button)
                }
            }
            stack.addArrangedSubview(row)
            if rowIndex < rows.count - 1 {
                stack.setCustomSpacing(Self.letterRowSpacing, after: row)
            }
        }
    }

    private func t9AccessibilityLabel(for identifier: String, title: String) -> String {
        switch identifier {
        case "t9.punctuation": return "常用标点"
        case "t9.delete": return "删除"
        case "t9.clear": return "清空拼音组合"
        case "t9.separator": return "插入拼音分词"
        default: return title.replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// 数字符号页复用字母页的颜色、字号、45pt 键高和 11pt 行距，不引入另一套视觉参数。
    private func addSymbolRows(to stack: UIStackView) {
        stack.addArrangedSubview(makeEqualKeyRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]))
        stack.addArrangedSubview(makeEqualKeyRow(["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""]))

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = Self.hGap
        bottom.distribution = .fillEqually
        activateGeometry(bottom.heightAnchor.constraint(equalToConstant: Self.letterKeyHeight))
        [".", ",", "?", "!", "'", "#", "%", "+", "="].forEach {
            bottom.addArrangedSubview(makeKey($0))
        }
        configureButton(symbolDeleteButton, title: nil, symbol: "delete.left", style: .utility)
        symbolDeleteButton.addTarget(self, action: #selector(deleteBackward), for: .primaryActionTriggered)
        bottom.addArrangedSubview(symbolDeleteButton)
        stack.addArrangedSubview(bottom)
    }

    private func makeEqualKeyRow(_ values: [String]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Self.hGap
        row.distribution = .fillEqually
        activateGeometry(row.heightAnchor.constraint(equalToConstant: Self.letterKeyHeight))
        values.forEach { row.addArrangedSubview(makeKey($0)) }
        return row
    }

    private func updateKeyboardCharacterPage(animated: Bool) {
        keycapPreview.hide()
        let showingLetters = keyboardCharacterPage == .letters
        let showingNineKey = showingLetters && chineseMode && chineseKeyboardLayout == .nineKey
        let showingTwentySixKey = showingLetters && !showingNineKey
        let changes = {
            self.letterKeyboardView?.alpha = showingTwentySixKey ? 1 : 0
            self.letterKeyboardView?.transform = showingTwentySixKey
                ? .identity
                : CGAffineTransform(scaleX: 0.98, y: 0.98)
            self.nineKeyKeyboardView?.alpha = showingNineKey ? 1 : 0
            self.nineKeyKeyboardView?.transform = showingNineKey
                ? .identity
                : CGAffineTransform(scaleX: 0.98, y: 0.98)
            self.symbolKeyboardView?.alpha = showingLetters ? 0 : 1
            self.symbolKeyboardView?.transform = showingLetters
                ? CGAffineTransform(scaleX: 0.98, y: 0.98)
                : .identity
        }
        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: changes
            )
        } else {
            changes()
        }
        letterKeyboardView?.isUserInteractionEnabled = showingTwentySixKey
        nineKeyKeyboardView?.isUserInteractionEnabled = showingNineKey
        symbolKeyboardView?.isUserInteractionEnabled = !showingLetters
        updateLeftFunctionButton()
        updateLayoutButton()
    }

    /// 每个字母键宽度固定为 k(与所在行的 widthAnchor 联立求解),三排通用。
    /// ★必须在 addArrangedSubview 之后调用:跨视图 anchor 约束激活时两端必须已有共同祖先,
    /// 否则 NSGenericException("no common ancestor")在 viewDidLoad 里秒崩、键盘扩展进程
    /// 启动即死,系统表现为"该键盘唤不起来"(2026-07-13 第十三轮 F 崩溃回归的根因)。
    private func pinKeyWidth(_ button: UIButton, to row: UIStackView) {
        activateGeometry(button.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                        multiplier: Self.keyWidthMultiplier,
                                                        constant: Self.keyWidthConstant))
    }

    /// 第 1 排:q–p 10 键,贴 sideInset 排满,键宽 k、间隙 hGap。
    ///
    /// 2026-08-03:改用 `.fillEqually`,不再给 10 个键各挂一条 999 优先级的宽度约束。
    /// 几何完全等价——`.fillEqually` 得到的正是 k = (Wc − 9×hGap) / 10——但少了 10 条
    /// 可被 Auto Layout 断开的约束。旧写法下这 10 条与 UIStackView 内部 required 约束联立,
    /// 一旦出现浮点残差或异常容器尺寸,系统会挑其中**一条**断开(见 activateGeometry 注释),
    /// 被挑中的那一个键就会失去宽度、错位并且点不中——真机上稳定表现为"e 键显示异常且无法点击"。
    /// 符号页的 `makeEqualKeyRow` 一直用的就是这个写法,从未出现同类问题。
    private func makeTopLetterRow() -> UIStackView {
        makeEqualKeyRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
    }

    /// 第 2 排:a–l 9 键,键宽 k,整排居中(左右各留约半键宽的弹性留白)。
    private func makeMiddleLetterRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 0   // 键间距改由 setCustomSpacing 逐一设置,避免 spacer 两端多算一份 hGap
        row.distribution = .fill
        activateGeometry(row.heightAnchor.constraint(equalToConstant: Self.letterKeyHeight))

        // 先把两个 spacer 都放进行内、再建跨视图宽度约束(激活时必须已有共同祖先,见 pinKeyWidth 注释);
        // spacerRight 提前 add 不影响排序——下面字母键用 insert(at:) 依次插到它前面。
        let spacerLeft = UIView()
        let spacerRight = UIView()
        row.addArrangedSubview(spacerLeft)
        row.addArrangedSubview(spacerRight)
        [spacerLeft, spacerRight].forEach {
            activateGeometry($0.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                        multiplier: Self.row2SpacerMultiplier,
                                                        constant: Self.row2SpacerConstant))
        }

        let letters = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
        for (index, letter) in letters.enumerated() {
            let key = makeKey(letter)
            row.insertArrangedSubview(key, at: row.arrangedSubviews.count - 1)   // 保持 spacerRight 恒为最后
            pinKeyWidth(key, to: row)
            if index < letters.count - 1 {
                row.setCustomSpacing(Self.hGap, after: key)
            }
        }
        return row
    }

    /// 第 3 排:shift 贴左缘、删除键贴右缘(宽约 1.25k),z–m 7 键宽 k 居中,
    /// 两侧字母区与 shift/删除之间的留白明显大于 hGap。
    private func makeBottomLetterRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 0   // 间隙均由显式 spacer / setCustomSpacing 控制
        row.distribution = .fill
        activateGeometry(row.heightAnchor.constraint(equalToConstant: Self.letterKeyHeight))

        // 全部先 addArrangedSubview、后建跨视图宽度约束(激活时必须已有共同祖先,见 pinKeyWidth 注释)。
        let shiftButton = KeyFieldButton(type: .system)
        configureButton(shiftButton, title: nil, symbol: "shift", style: .utility)
        shiftButton.addTarget(self, action: #selector(toggleShift), for: .primaryActionTriggered)
        row.addArrangedSubview(shiftButton)
        activateGeometry(shiftButton.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                             multiplier: Self.sideKeyWidthMultiplier,
                                                             constant: Self.sideKeyWidthConstant))

        let gapLeft = UIView()
        row.addArrangedSubview(gapLeft)
        activateGeometry(gapLeft.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                         multiplier: Self.row3GapMultiplier,
                                                         constant: Self.row3GapConstant))

        let letters = ["z", "x", "c", "v", "b", "n", "m"]
        for (index, letter) in letters.enumerated() {
            let key = makeKey(letter)
            row.addArrangedSubview(key)
            pinKeyWidth(key, to: row)
            if index < letters.count - 1 {
                row.setCustomSpacing(Self.hGap, after: key)
            }
        }

        let gapRight = UIView()
        row.addArrangedSubview(gapRight)
        activateGeometry(gapRight.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                          multiplier: Self.row3GapMultiplier,
                                                          constant: Self.row3GapConstant))

        configureButton(deleteButton, title: nil, symbol: "delete.left", style: .utility)
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .primaryActionTriggered)
        row.addArrangedSubview(deleteButton)
        activateGeometry(deleteButton.widthAnchor.constraint(equalTo: row.widthAnchor,
                                                              multiplier: Self.sideKeyWidthMultiplier,
                                                              constant: Self.sideKeyWidthConstant))

        return row
    }

    private func makeKey(_ value: String) -> UIButton {
        let button = KeyFieldButton(type: .system)
        configureButton(button, title: displayValue(for: value), symbol: nil, style: .key)
        button.accessibilityIdentifier = value
        button.addTarget(self, action: #selector(insertKey(_:)), for: .primaryActionTriggered)
        keyButtons.append(button)
        return button
    }

    private func displayValue(for value: String) -> String {
        guard value.count == 1, value.rangeOfCharacter(from: .letters) != nil else { return value }
        return isUppercase ? value.uppercased() : value
    }

    /// 从 App Group 取走待插入文本(需「允许完全访问」)。
    /// 付费桥可用时文本走 App Group 快照,不需要(也不应该)读剪贴板这个跨进程 IPC。
    @discardableResult
    private func drainPendingText() -> Bool {
        let expectedRequestID = bridgeLive ? KeyboardBridgeStore.snapshot().resultRequestID : nil
        return drainPendingText(expectedRequestID: expectedRequestID)
    }

    /// 使用调用者已经读取的 request ID 消费结果，避免一次轮询内二次读取共享快照。
    /// 成功插入是比跨进程 phase 更强的终止事实：此处必须同步结束本地 processing UI，
    /// 不能依赖下一次 0.5 秒轮询（键盘扩展可能在此刻被宿主暂停）。
    private var deliveringPendingText = false

    @discardableResult
    private func drainPendingText(expectedRequestID: String?) -> Bool {
        guard hasFullAccess, !deliveringPendingText else { return false }
        deliveringPendingText = true
        defer { deliveringPendingText = false }
        editReplacementFailed = false
        if !bridgeLive {
            // 降级模式也只在一次真实语音请求后的有限窗口内检查；先看 privacy-safe 的
            // changeCount，确认结果确实发生变化后才读取内容。普通打字/编辑绝不读剪贴板。
            guard let until = plainPasteboardFallbackUntil, Date() < until else {
                clearPlainPasteboardFallback()
                return false
            }
            guard let baseline = plainPasteboardBaselineChangeCount,
                  UIPasteboard.general.changeCount != baseline else { return false }
        }
        let deliverySnapshot = KeyboardBridgeStore.snapshot()
        if bridgeLive, expectedRequestID?.hasPrefix("action:") != true {
            guard let expectedRequestID,
                  deliverySnapshot.resultRequestID == expectedRequestID,
                  deliverySnapshot.phase == .ready,
                  deliverySnapshot.insertedText.isEmpty else { return false }
            if let target = deliverySnapshot.returnTarget {
                guard (SWTReadHostValue(self, "_hostProcessIdentifier") as? NSNumber)?.intValue == target.pid else { return false }
                let document = textDocumentProxy.documentIdentifier
                guard document == target.documentID || document == deliverySnapshot.returnedDocumentID else {
                    showHostReturnMessage("请回到原输入框")
                    return false
                }
            }
        }
        let consumption = PendingTextStore.consume(
            expectedRequestID: expectedRequestID,
            allowPlainTextFallback: !bridgeLive,
            insert: { [weak self] text in
                // 遮挡故障只发生在回填之后(§11.1a),回填前后各钉一个采样点,
                // 才能把"键盘上移了"和"输入框下移了"分开。
                self?.logGeometry("insert-before")
                guard let self else { return }
                // 是否是修改模式的交付,靠 App Group 里持久化的 editBaseText 判断,
                // 不靠本地的 `editModeActive`。录音→ASR→LLM 这一趟常常要几秒到十几秒,
                // 键盘扩展进程随时可能被系统在这期间回收重建(切了一次输入框、内存紧张
                // 都可能触发)——本地属性重启就丢,持久化的桥快照不会。实测复现的
                // "新话追加在原话后面"根因就在这里:本地 editModeActive 已经丢了,
                // 交付时误判成普通口述,走了没有删除动作的插入路径。
                if let baseText = KeyboardBridgeStore.snapshot().editBaseText, !baseText.isEmpty {
                    self.applyEditReplacement(newText: text, baseText: baseText)
                } else {
                    // Only the final cleanup payload writes into the host document.
                    self.textDocumentProxy.insertText(self.boundaryAdjusted(text))
                }
            },
            acknowledge: { text in
                KeyboardBridgeStore.markInserted(text, requestID: expectedRequestID)
            },
            didInsert: { !self.editReplacementFailed }
        )
        if case .handedOff = consumption {
            KeyboardBridgeStore.markHandedOff(requestID: expectedRequestID)
            currentBridgePhase = .error
            currentProcessingStage = nil
            processingBeganAt = nil
            recognitionProgress = 0
            lastInsertedText = ""
            clearPlainPasteboardFallback()
            updateVoiceHeader(phase: .error)
            showHostReturnMessage("修改失败，新稿已复制，请手动粘贴")
            setSpaceHint("修改失败,新稿已复制")
            editReplacementFailed = false
            return false
        }
        if case .inserted(let text) = consumption {
            hostReturnMessageLabel.isHidden = true
            DiagLog.log("insert", "已插入 \(text.count) 字: \(text.prefix(20))")
            // 修改键的前置校验要靠这个比对"宿主里的内容仍是上次插入的那段";
            // .noEdit/.unchanged 也会走到这里(推回的是原样 baseText),同样更新为准。
            // editModeActive 的清理已经在 applyEditReplacement 的 defer 里做了。
            lastInsertedText = text
            auditHeightAfterInsertion()
            clearPlainPasteboardFallback()

            // 插入完成即是本地权威终态。先清掉 processing 的本地动画状态，再刷新整套
            // 语音面；这样即使宿主随后暂停扩展、下一轮 bridgeTimer 永远不执行，也不会
            // 把 97% 的“正在整理”画面冻结在键盘上。
            currentBridgePhase = .inserted
            currentProcessingStage = nil
            processingBeganAt = nil
            recognitionProgress = 0
            updateVoiceHeader(phase: .inserted)
            refreshFaceSwitch()
            if bridgeLive {
                updateVoiceButton(
                    isAppAwake: KeyboardBridgeStore.isAppAwake(),
                    canSendDirectly: KeyboardBridgeStore.canAcceptDirectKeyboardRequest(),
                    phase: .inserted
                )
            }
            // This branch runs only after this consumer actually inserts a new payload.
            showInsertedConfirmation()
            // 顶部栏不显示“已插入”确认；但修改无法清空时必须保留人工接管提示，
            // 告知用户新稿已经在剪贴板，而不是误以为它已自动替换成功。
            if self.editReplacementFailed {
                setSpaceHint("修改失败,新稿已复制")
            } else {
                setSpaceHint(Self.hintIdle)
            }
            self.editReplacementFailed = false
            updateSendButtonAppearance(hasContent: false)
            updateCandidateBarVisibility()
            return true
        }
        if expectedRequestID != nil, case .busy = consumption {
            DiagLog.log("insert", "交付锁正忙，保留 payload 等待下次轮询")
        }
        return false
    }

    /// 向主 App 声明「Shall We Talk 键盘正在这个宿主输入框中」。
    /// 心跳仅在 App Group + 完全访问可用时发布，不触碰系统剪贴板。
    private func publishKeyboardPresence() {
        guard bridgeLive, hasFullAccess else { return }
        KeyboardBridgeStore.publishKeyboardPresence(
            sessionID: keyboardSessionID,
            documentID: textDocumentProxy.documentIdentifier
        )
    }

    /// Action Button 结果不复用普通键盘录音的 resultRequestID，而是另带一份
    /// 目标输入文档凭据。只有凭据与当前 `documentIdentifier` 一致才消费。
    @discardableResult
    private func drainActionKeyboardDelivery() -> Bool {
        guard bridgeLive, hasFullAccess else { return false }
        let documentID = textDocumentProxy.documentIdentifier
        guard let requestID = KeyboardBridgeStore.pendingActionKeyboardDelivery(for: documentID) else {
            return false
        }
        let inserted = drainPendingText(expectedRequestID: requestID)
        if inserted {
            KeyboardBridgeStore.acknowledgeActionKeyboardDelivery(requestID)
            DiagLog.log("insert", "Action Button 结果已直接插入当前 Shall We Talk 输入框")
        }
        return inserted
    }

    private func preparePlainPasteboardFallback(duration: TimeInterval, requiresChange: Bool) {
        plainPasteboardFallbackUntil = Date().addingTimeInterval(duration)
        plainPasteboardBaselineChangeCount = UIPasteboard.general.changeCount
    }

    private func clearPlainPasteboardFallback() {
        plainPasteboardFallbackUntil = nil
        plainPasteboardBaselineChangeCount = nil
    }

    @objc private func insertSpace() {
        // 组合中:空格 = 选第一个候选;否则插空格
        if pinyin.isComposing, let first = pinyin.candidates.first {
            selectCandidate(first)
            return
        }
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertReturn() {
        // 组合中先提交当前首选词，再执行宿主的回车语义；九键数字绝不能原样漏进正文。
        if pinyin.isComposing {
            commitBestCandidateIfNeeded()
        }
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteBackward() {
        // 组合中:退格删拼音缓冲的一个字母;否则删文档字符
        let computeStart = CFAbsoluteTimeGetCurrent()
        let handled = pinyin.backspace()
        let computeEnd = CFAbsoluteTimeGetCurrent()
        if handled {
            syncMarkedComposition()
            refreshCandidateBar(perfLabel: "退格", computeStart: computeStart, computeEnd: computeEnd)
            return
        }
        textDocumentProxy.deleteBackward()
    }

    @objc private func voiceDeleteBackward() {
        // 语音面没有拼音组合区，必须直接删除宿主输入框中的前一个字符。
        // 只记录字符数量用于诊断，避免把用户输入内容写入日志。
        let contextCount = textDocumentProxy.documentContextBeforeInput?.count ?? -1
        DiagLog.log("delete", "语音面删除点击 contextCount=\(contextCount)")
        textDocumentProxy.deleteBackward()
    }

    @objc private func insertKey(_ sender: UIButton) {
        guard let value = sender.accessibilityIdentifier else { return }
        // 中文模式 + 引擎就绪 + 小写字母 → 交给拼音引擎;否则直接上屏
        if chineseMode, !isUppercase, value.count == 1, let ch = value.first {
            // 词库未就绪:吞掉这一下并催加载,绝不原样上屏 —— pinyin.input() 此时返回 false,
            // 走下面的 insertText 会把裸拼音字母插进宿主输入框。字母键此刻本就是禁用的,
            // 这里是兜底(大写态、以及禁用状态之外的任何进入路径)。
            if !pinyin.isReady {
                ensureDictionaryLoaded()
                return
            }
            let computeStart = CFAbsoluteTimeGetCurrent()
            let handled = pinyin.input(ch)
            let computeEnd = CFAbsoluteTimeGetCurrent()
            if handled {
                syncMarkedComposition()
                refreshCandidateBar(perfLabel: "键入'\(ch)'", computeStart: computeStart, computeEnd: computeEnd)
                return
            }
        }
        textDocumentProxy.insertText(displayValue(for: value))
        if isUppercase { toggleShift() }
    }

    @objc private func insertT9Key(_ sender: UIButton) {
        guard chineseMode,
              chineseKeyboardLayout == .nineKey,
              let identifier = sender.accessibilityIdentifier,
              let digit = identifier.last,
              digit.isNumber else { return }
        guard pinyin.isReady else {
            ensureDictionaryLoaded()
            return
        }
        let computeStart = CFAbsoluteTimeGetCurrent()
        guard pinyin.inputT9Digit(digit) else { return }
        let computeEnd = CFAbsoluteTimeGetCurrent()
        syncMarkedComposition()
        refreshCandidateBar(perfLabel: "九键'\(digit)'", computeStart: computeStart, computeEnd: computeEnd)
    }

    @objc private func insertT9Punctuation() {
        guard !pinyin.isComposing else { return }
        textDocumentProxy.insertText("。")
    }

    @objc private func clearT9Composition() {
        guard pinyin.isComposing else { return }
        pinyin.clear()
        syncMarkedComposition()
        refreshCandidateBar()
    }

    @objc private func insertT9Separator() {
        guard pinyin.inputSeparator() else { return }
        syncMarkedComposition()
        refreshCandidateBar()
    }

    @objc private func toggleShift() {
        isUppercase.toggle()
        for button in keyButtons {
            guard let value = button.accessibilityIdentifier else { continue }
            button.configuration?.title = displayValue(for: value)
        }
    }

    // MARK: - 中文输入态

    /// 将拼音组合串交给宿主文本框管理。支持 marked text 的宿主会按系统方式显示下划线，
    /// 光标始终位于组合串末尾；候选栏不再重复显示这段内容。
    private func syncMarkedComposition() {
        let composition = pinyin.displayComposition
        guard !composition.isEmpty else {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
            return
        }
        textDocumentProxy.setMarkedText(
            composition,
            selectedRange: NSRange(location: composition.utf16.count, length: 0)
        )
    }

    /// 用最终文字替换当前 marked text 并提交，避免把候选追加在拼音串后面。
    private func commitMarkedText(_ text: String) {
        guard !text.isEmpty else { return }
        // insertText让宿主把当前组合替换成已提交的文字。
        // setMarkedText(选词)→unmarkText→setMarkedText(余串)在真实扩展通道中
        // 会让后一个组合覆盖前一个选词；不能用这组三步模拟一次提交。
        textDocumentProxy.insertText(text)
    }

    /// 从字母页进入数字符号页前，按当前首选词提交完整组合；若没有候选则原样提交拼音。
    private func commitBestCandidateIfNeeded() {
        var remainingSelections = 32
        while pinyin.isComposing, remainingSelections > 0, let first = pinyin.candidates.first {
            let previousCount = pinyin.buffer.count
            let selection = pinyin.select(first)
            commitMarkedText(selection.text)
            SharedDictionaryStore.recordSelection(first.word)
            loadHotwordsIfNeeded()
            guard selection.hasRemainder, pinyin.buffer.count < previousCount else { break }
            syncMarkedComposition()
            remainingSelections -= 1
        }
        if pinyin.isComposing {
            commitMarkedText(pinyin.commitRaw())
        }
        refreshCandidateBar()
    }

    @objc private func toggleLanguage() {
        if chineseMode, pinyin.isComposing {
            commitBestCandidateIfNeeded()
        }
        chineseMode.toggle()
        // 切回中文才需要词库;切到英文不卸载 —— 中英来回切是高频操作,
        // 每次都卸载重载会把加载耗时摊到每一次切换上。真正的释放点是切回语音面。
        if chineseMode {
            pinyin.setInputMode(chineseKeyboardLayout == .nineKey ? .nineKey : .twentySixKey)
            ensureDictionaryLoaded()
        }
        updateKeyboardCharacterPage(animated: true)
        updateLayoutButton()
        updateLangButton()
        refreshCandidateBar()
        updateLetterKeysEnabled()
    }

    private func updateLangButton() {
        langButton.configuration?.title = nil
        let title = NSMutableAttributedString(string: "中 / 英")
        title.addAttributes([
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: KeyboardTheme.ink(alpha: chineseMode ? 1 : 0.45)
        ], range: NSRange(location: 0, length: 1))
        title.addAttributes([
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: KeyboardTheme.ink(alpha: 0.30)
        ], range: NSRange(location: 1, length: 3))
        title.addAttributes([
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: KeyboardTheme.ink(alpha: chineseMode ? 0.45 : 1)
        ], range: NSRange(location: 4, length: 1))
        langButton.setAttributedTitle(title, for: .normal)
        langButton.accessibilityLabel = chineseMode ? "切换到英文" : "切换到中文"
        // 原来是 `ready || !chineseMode`:词库没就绪就禁用中/英键。改成按需加载后
        // "未就绪"变成了正常的过渡态,再禁用会把用户困死 —— 字母键此刻也是灰的,
        // 他既打不了字、又切不到英文。中/英键必须始终可用,那正是唯一的出口。
        langButton.isEnabled = true
    }

    /// 重算并刷新候选词。已键入的拼音只通过宿主输入框的 marked text 显示，
    /// 候选栏从固定左缘开始，只画候选按钮。
    /// computeStart/computeEnd:调用方(insertKey/deleteBackward/selectCandidate)传入的"敲键→候选算完"耗时,
    /// 用于 [KB][perf] 诊断日志;不传则不记该段。
    private func refreshCandidateBar(perfLabel: String = "", computeStart: CFAbsoluteTime? = nil, computeEnd: CFAbsoluteTime? = nil) {
        if chineseMode, !pinyin.dictionaryReady {
            // 槽位是常驻的,这里只清空内容,不拆视图——拆了就得重建,等分宽度会抖一帧。
            visibleCandidates.removeAll()
            layoutCandidateBar()
            updateCandidateBarVisibility()
            return
        }
        logComputeIfSlow(perfLabel: perfLabel, start: computeStart, end: computeEnd)
        scheduleCandidateRender(perfLabel: perfLabel)
        updateCandidateBarVisibility()
    }

    /// [KB][perf] "敲键→候选算完"耗时,仅超过一帧(perfLogThresholdMs)才落盘。
    private func logComputeIfSlow(perfLabel: String, start: CFAbsoluteTime?, end: CFAbsoluteTime?) {
        guard let start, let end, !perfLabel.isEmpty else { return }
        let ms = (end - start) * 1000
        guard ms > Self.perfLogThresholdMs else { return }
        DiagLog.log("perf", "\(perfLabel) 候选计算=\(String(format: "%.1f", ms))ms 候选数=\(pinyin.candidates.count)")
    }

    /// 同步渲染候选按钮。
    ///
    /// 2026-08-04 去掉了原来 24ms 的 `asyncAfter` 防抖。那 24ms 是**每次敲键人为加的**约 1.5 帧
    /// 延迟,而真机诊断日志显示:连续几分钟打字,`[KB][perf]` 一条都没有——"敲键→候选算完"和
    /// "候选→渲染完成"从未超过 16ms 的阈值。防抖在防一个不存在的问题,只留下了延迟本身。
    /// 埋点保留:如果哪天候选真的算慢了,日志会立刻显形。
    private func scheduleCandidateRender(perfLabel: String) {
        let items = pinyin.candidates
        let renderStart = CFAbsoluteTimeGetCurrent()
        renderCandidates(items)
        let ms = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000
        guard ms > Self.perfLogThresholdMs else { return }
        let label = perfLabel.isEmpty ? "候选渲染" : perfLabel
        DiagLog.log("perf", "\(label) 候选渲染=\(String(format: "%.1f", ms))ms 按钮数=\(min(items.count, Self.maxVisibleCandidates))")
    }

    private func renderCandidates(_ items: [PinyinCandidate]) {
        let visible = Array(items.prefix(Self.maxVisibleCandidates))
        visibleCandidates = visible   // candidateTapped 按此数组取词,与实际画出来的按钮 tag 保持一致
        layoutCandidateBar()
        candidateScroll.setContentOffset(.zero, animated: false)
    }

    /// 先按实测宽度选模式,再刷标题。渲染和 `viewDidLayoutSubviews`(候选栏宽度变化时)共用。
    private func layoutCandidateBar() {
        applyCandidateBarMode(fixedSlots: candidatesFitFixedSlots(visibleCandidates))
        for (i, button) in candidateButtons.enumerated() {
            button.tag = i
            let word = i < visibleCandidates.count ? visibleCandidates[i].word : nil
            setCandidateTitle(word, on: button, isTop: i == 0)
        }
    }

    /// 固定槽位模式下 contentInsets = 0,可用宽就是槽宽本身;这 2pt 只是不让字形贴死槽边。
    private static let candidateFitMargin: CGFloat = 2

    /// 这一批候选能否整批塞进等宽槽——**唯一决定用哪种排布的判据**。
    ///
    /// 关键在于:判定用的字体对象和真正渲染用的是同一个,量的槽宽也是真实 bounds 等分出来的,
    /// 所以"判定说放得下"⇒ 渲染必然放得下。**不省略这条硬规则不依赖任何关于汉字字宽的假设**,
    /// 换字体、换机型、换字号都不会破。字数只是结果:420pt 机型上槽宽 54.8pt,
    /// 17pt 汉字约 17pt/字,于是 ≤3 字走固定槽、≥4 字整批退回变宽。
    ///
    /// 首帧 bounds 还是 0,此时先按固定槽走,`viewDidLayoutSubviews` 拿到真宽后会复算一次。
    private func candidatesFitFixedSlots(_ candidates: [PinyinCandidate]) -> Bool {
        let barWidth = candidateScroll.bounds.width
        guard barWidth > 0 else { return true }
        let slot = barWidth / CGFloat(Self.maxVisibleCandidates)
        return candidates.allSatisfy { entry in
            let width = (entry.word as NSString)
                .size(withAttributes: [.font: Self.candidateFont]).width
            return width <= slot - Self.candidateFitMargin
        }
    }

    /// 用 attributedTitle 钉字体:`titleTextAttributesTransformer` 是建按钮时设死的,
    /// 这里还要按模式切 contentInsets,索性统一在这一处写。
    ///
    /// 空槽的处理是两种模式的关键差异:固定槽位下**绝不能 isHidden**——UIStackView 会把隐藏的
    /// arrangedSubview 从等分里剔除,候选数从 6 掉到 3 时剩下的会各自变宽一倍、位置全变;
    /// 变宽模式下则必须隐藏,否则空按钮会占掉 spacing、在末尾留一串空隙。
    private func setCandidateTitle(_ word: String?, on button: UIButton, isTop: Bool) {
        guard var configuration = button.configuration else { return }
        let inset = candidateBarUsesFixedSlots ? 0 : Self.candidateLooseInset
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: inset, bottom: 0, trailing: inset
        )
        guard let word, !word.isEmpty else {
            configuration.attributedTitle = nil
            button.configuration = configuration
            button.isEnabled = false
            button.isHidden = !candidateBarUsesFixedSlots
            return
        }
        var title = AttributedString(word)
        title.font = Self.candidateFont
        title.foregroundColor = isTop ? KeyboardTheme.ink : KeyboardTheme.ink(alpha: 0.65)
        configuration.attributedTitle = title
        button.configuration = configuration
        button.isEnabled = true
        button.isHidden = false
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        // 用 visibleCandidates(渲染时的快照)而非 pinyin.candidates:按钮 tag 必须对应
        // "当前实际画出来的候选",否则会选中错误的词。
        guard sender.tag < visibleCandidates.count else { return }
        selectCandidate(visibleCandidates[sender.tag])
    }

    private func selectCandidate(_ entry: PinyinCandidate) {
        let computeStart = CFAbsoluteTimeGetCurrent()
        let sel = pinyin.select(entry)
        let computeEnd = CFAbsoluteTimeGetCurrent()
        guard !sel.text.isEmpty else { return }
        commitMarkedText(sel.text)
        if sel.hasRemainder {
            syncMarkedComposition()
        }
        SharedDictionaryStore.recordSelection(entry.word)
        loadHotwordsIfNeeded()
        refreshCandidateBar(perfLabel: "选词'\(entry.word)'", computeStart: computeStart, computeEnd: computeEnd)
    }

    private func updateCandidateBarVisibility() {
        let show = chineseMode && pinyin.isComposing
        candidateScroll.isHidden = !show
    }

    // MARK: - 词库按需加载 / 卸载(2026-08-11,build 128)
    //
    // 词库只在**字母键盘的中文模式**下用得到:`pinyin.*` 的全部调用点都在字母面
    // (敲键、退格、候选栏、中/英键、热词注入),语音面上候选栏是隐藏的、中/英键也不在那一面。
    // 而原来的代码在 `viewDidLoad` 无条件加载,默认面又恰恰是语音面 —— 等于每个键盘实例
    // 一起来就把整本词库读进内存,哪怕这一次从头到尾只用语音。日志显示实例在 35 分钟里
    // 被重建 27 次,也就是这笔开销被反复付了 27 次。
    //
    // 用户 2026-08-11 拍板:切到字母键盘才加载,切回语音面就卸载,并明确接受
    // "切过去要等加载完才能输入"。

    /// 按需加载。已就绪或正在加载都直接返回,可以随便重复调用。
    private func ensureDictionaryLoaded() {
        guard !pinyin.isReady, !isLoadingDictionary else { return }
        isLoadingDictionary = true
        let began = CFAbsoluteTimeGetCurrent()
        DiagLog.log("kbDict", "开始加载 \(Self.memoryText())")
        updateLetterKeysEnabled()
        pinyin.loadAsync { [weak self] in
            guard let self else { return }
            self.isLoadingDictionary = false
            let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
            DiagLog.log("kbDict", String(
                format: "加载完成 耗时=%.0fms 词条=%d ",
                ms, self.pinyin.dictionary.loadedEntryCount) + Self.memoryText())
            self.loadHotwordsIfNeeded(force: true)   // 词库换了新实例,热词必须重注入
            self.updateLangButton()
            self.refreshCandidateBar()
            self.updateLetterKeysEnabled()
        }
    }

    private func unloadDictionary(reason: String) {
        guard pinyin.isReady || isLoadingDictionary else { return }
        // 先把半截拼音按首选词落地,和 leftFunctionTapped 进符号页的处理一致:
        // 否则卸载后组合态没了,宿主输入框里会留下一段永远提交不掉的 marked text。
        if pinyin.isComposing { commitBestCandidateIfNeeded() }
        isLoadingDictionary = false
        pinyin.unload()
        DiagLog.log("kbDict", "已卸载(\(reason)) \(Self.memoryText())")
        // malloc 未必立刻把页还给系统,+1s 再采一次才看得出真实回收量。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DiagLog.log("kbDict", "卸载后+1s \(Self.memoryText())")
        }
        updateLangButton()
        updateCandidateBarVisibility()
        updateLetterKeysEnabled()
    }

    /// 中文模式下词库未就绪时,字母键置灰不可点。用户明确接受"等加载完才能输入",
    /// 这比让裸拼音字母漏进宿主输入框好 —— `PinyinEngine.input()` 在未就绪时返回 false,
    /// 原路径会把 `n` 原样插进微信。英文模式不吃词库,字母键永远可用。
    private func updateLetterKeysEnabled() {
        let usable = !chineseMode || pinyin.isReady
        for button in keyButtons {
            guard let value = button.accessibilityIdentifier,
                  value.count == 1, value.first?.isLetter == true else { continue }
            button.isEnabled = usable
        }
        for button in t9InputButtons {
            button.isEnabled = chineseMode && pinyin.isReady
        }
    }

    /// 从 App Group 读语音词典,转拼音注入引擎(同源)。version 变化才重注入。
    private func loadHotwordsIfNeeded(force: Bool = false) {
        guard pinyin.isReady else { return }
        let v = SharedDictionaryStore.version()
        guard force || v != loadedHotwordVersion else { return }
        loadedHotwordVersion = v
        let words = SharedDictionaryStore.words()
        guard !words.isEmpty else { return }
        pinyin.setHotwords(words)
    }
}
