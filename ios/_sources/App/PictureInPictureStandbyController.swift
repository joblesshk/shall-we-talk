@preconcurrency import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import ObjectiveC
import UIKit
import os.log

/// AVSampleBufferVideoRenderer 不是 Apple 标注的 Sendable 类型,但本文件里所有
/// `weak renderer` 捕获都只出现在 `requestMediaDataWhenReady`/`flush` 的
/// `@Sendable` 完成回调里,且回调一进来就先 `MainActor.assumeIsolated` 或
/// `Task { @MainActor ... }` 重新隔离,真正读写 renderer 状态前都已经回到主线程。
/// 这里断言的是"按本文件的实际用法安全",不是"这个类型本身线程安全"。
extension AVSampleBufferVideoRenderer: @unchecked Sendable {}

/// Typeless 的 Pegasus 日志同时出现 VideoCall content type、
/// RoutingVideoToHostedWindow 与 5040 x 1 sample-buffer renderer。因此不能只把
/// display layer 直接当作普通 PiP content source；它必须由真正的
/// video-call 托管容器承载。
@MainActor
private final class StandbyVideoCallContentViewController:
    AVPictureInPictureVideoCallViewController
{
    private let hostedDisplayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        hostedDisplayLayer = displayLayer
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(
            width: 369,
            height: 369 / CGFloat(5040)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentView = UIView(
            frame: CGRect(x: 0, y: 0, width: 5040, height: 1)
        )
        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        hostedDisplayLayer.removeFromSuperlayer()
        hostedDisplayLayer.frame = contentView.bounds
        contentView.layer.addSublayer(hostedDisplayLayer)
        view = contentView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedDisplayLayer.frame = view.bounds
        CATransaction.commit()
    }
}

/// 用 sample-buffer PiP 维持主 App 的后台可调度状态。空闲时麦克风与
/// AVAudioEngine 均关闭；这里只维护一个极端宽高比、低帧率的视频时间轴。
@MainActor
final class PictureInPictureStandbyController: NSObject, StandbyMechanism {
    static let shared = PictureInPictureStandbyController()

    private static let log = OSLog(
        subsystem: "org.example.voicepen",
        category: "PictureInPictureStandby"
    )
    /// Typeless 真机日志的实测值。5040:1 在 AVKit 中被缩放为
    /// 369 x 0.0732 pt，SpringBoard 最终将 PiP 交互布局取整为 0 pt 高。
    private static let frameWidth = 5040
    private static let frameHeight = 1
    /// 实测为每 2 秒补一帧，PTS 每次前进 1 秒，即 0.5 倍时间轴。
    private static let frameInterval: TimeInterval = 2
    private static let frameDuration = CMTime(value: 1, timescale: 1)
    private static let playbackRate: Float64 = 0.5
    /// Typeless 真机启动时的实测序列：先以 HomeKitCamera(3)
    /// 创建 SecurityCamera PiP 交互容器，启动后再切到 VideoCall(4)。
    /// 这两个值是 AVKit 私有 controlsStyle，仅用于真机自签验证。
    private static let homeKitCameraControlsStyle = 3
    private static let videoCallControlsStyle = 4
    private static let controlsStyleTransitionDelay: TimeInterval = 0.3
    /// Pegasus 在相机等系统中断导致 PiP 停止后，会短暂保留一个
    /// "interruption began" process assertion。必须在这个窗口内重建并启动
    /// controller；否则主 App 很快被挂起，键盘桥也随之失去后台资格。
    private static let unexpectedStopRecoveryDelay: TimeInterval = 0.35
    private static let unexpectedStopRecoveryTimeout: TimeInterval = 3
    /// 保持 6 秒媒体时间（约 12 秒真实时间）的前置缓冲。系统合并后台定时器时，
    /// renderer 仍然有连续帧可用，不会因为一次延迟立即进入空队列。
    private static let bufferedMediaLead = CMTime(value: 6, timescale: 1)
    private static let rendererRecoveryGrace: TimeInterval = 0.75

    private let displayLayer = AVSampleBufferDisplayLayer()
    private lazy var videoCallContentViewController =
        StandbyVideoCallContentViewController(displayLayer: displayLayer)
    private var pictureInPictureController: AVPictureInPictureController?
    private let mediaFeederQueue = DispatchQueue(
        label: "org.example.voicepen.pip-media-feeder",
        qos: .utility
    )
    private var frameTimer: DispatchSourceTimer?
    private var isRequestingMediaData = false
    private var isRecoveringRenderer = false
    private var rendererFailureFirstSeenAt: Date?
    private var rendererRecoveryTask: Task<Void, Never>?
    private var controlsStyleTransitionTask: Task<Void, Never>?
    private var unexpectedStopRecoveryTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var pixelBuffer: CVPixelBuffer?
    private var formatDescription: CMVideoFormatDescription?
    private var timebase: CMTimebase?
    private var nextPresentationTime = CMTime.zero
    private var startupFailure: NSError?
    /// 每次用户启动或显式停止都会推进代号。AVKit 的 delegate 可能在 stop() 之后
    /// 才送达；只有 controller 身份和代号都匹配的回调才有权改变当前状态。
    private var sessionGeneration: UInt64 = 0
    private var requestedGeneration: UInt64?
    private var controllerGeneration: UInt64?
    private weak var sourceView: UIView?
    private(set) var isActive = false
    private(set) var startWasRequested = false
    private(set) var isRecoveringUnexpectedSystemStop = false
    var onStopped: (() -> Void)?

    private override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.isOpaque = false
        configureTimebase()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        let renderer = displayLayer.sampleBufferRenderer
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: renderer,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rendererRecoveryRequirementDidChange()
                }
            }
        )
    }

    @objc private func applicationDidBecomeActive() {
        guard sourceView != nil, hasValidSession else { return }
        startFramePump()
    }

    @objc private func applicationDidEnterBackground() {
        // 正在建立或已经建立 PiP 时继续供帧；普通退后台则不做无意义唤醒。
        if !hasValidSession {
            stopFramePump()
        }
        recordDiagnostic(
            "lifecycle didEnterBackground appState=\(UIApplication.shared.applicationState.rawValue) "
                + "PiP=\(isActive) requested=\(startWasRequested)"
        )
    }

    enum StartError: LocalizedError {
        case unsupported
        case sourceUnavailable
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "这台 iPhone 不支持画中画"
            case .sourceUnavailable:
                return "画中画媒体层尚未准备好，请稍后重试"
            case .unavailable(let details):
                return "系统暂时无法启动画中画（\(details)）"
            }
        }
    }

    /// 根视图作为 active video-call source view；透明 sample-buffer layer
    /// 实际挂在 AVKit 托管的 video-call content view 中。
    func attachSource(to view: UIView) {
        view.isOpaque = false
        sourceView = view
        let hostedView = videoCallContentViewController.view
        if displayLayer.superlayer !== hostedView?.layer {
            displayLayer.removeFromSuperlayer()
            hostedView?.layer.addSublayer(displayLayer)
        }
        layoutSource(in: view)
        prepareMediaIfNeeded()
        prepareControllerIfPossible()
    }

    func layoutSource(in view: UIView) {
        _ = view
        let hostedView = videoCallContentViewController.view
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = hostedView?.bounds ?? CGRect(
            x: 0,
            y: 0,
            width: Self.frameWidth,
            height: Self.frameHeight
        )
        CATransaction.commit()
    }

    func detachSource(from view: UIView) {
        guard sourceView === view else { return }
        sourceView = nil
        if !isActive {
            displayLayer.removeFromSuperlayer()
            stopFramePump()
        }
    }

    /// 必须直接从设置开关的用户事件栈调用；AVKit 可能忽略稍后异步发出的启动请求。
    @discardableResult
    func requestStartFromUserAction() -> Bool {
        prepareMediaIfNeeded()
        prepareControllerIfPossible()
        guard let controller = pictureInPictureController else {
            recordDiagnostic("用户点击时 sample-buffer PiP controller 尚未准备")
            return false
        }
        // 一帧预备数据通常已经足以使 possible=true；若系统仍未就绪，本次点击
        // 不建立有效会话，避免稍后的生命周期回调凭空启动 frame pump。
        guard controller.isPictureInPicturePossible else {
            recordDiagnostic(
                "用户点击时 possible=false bounds=\(sourceView?.bounds ?? .zero) "
                    + "window=\(sourceView?.window != nil) renderer=\(displayLayer.sampleBufferRenderer.status.rawValue)"
            )
            return false
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        requestedGeneration = generation
        controllerGeneration = generation
        startupFailure = nil
        controlsStyleTransitionTask?.cancel()
        controlsStyleTransitionTask = nil
        startWasRequested = true
        startFramePump()
        controller.startPictureInPicture()
        recordDiagnostic("用户点击事件内已调用 sample-buffer startPictureInPicture generation=\(generation)")
        return true
    }

    func start() async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw StartError.unsupported
        }
        if isActive { return }
        guard startWasRequested,
              let generation = requestedGeneration,
              let controller = pictureInPictureController,
              isCurrentSession(controller, generation: generation) else {
            throw StartError.unavailable("请关闭开关后重新开启")
        }

        startFramePump()
        for _ in 0..<40 {
            prepareMediaIfNeeded()
            guard isCurrentSession(controller, generation: generation) else {
                throw StartError.unavailable("画中画启动已取消")
            }
            if sourceView?.window != nil, controller.isPictureInPicturePossible {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let sourceView,
              sourceView.window != nil else {
            recordDiagnostic("常驻 source view 未入窗口")
            throw StartError.sourceUnavailable
        }
        guard controller.isPictureInPicturePossible else {
            throw StartError.unavailable("媒体层尚未就绪")
        }
        guard isCurrentSession(controller, generation: generation) else {
            throw StartError.unavailable("画中画启动已取消")
        }

        recordDiagnostic(
            "等待启动 source=sampleBuffer requested=true possible=true "
                + "bounds=\(sourceView.bounds) cadence=\(Self.frameInterval)s generation=\(generation)"
        )
        for _ in 0..<200 {
            if controller.isPictureInPictureActive || isActive || startupFailure != nil { break }
            guard isCurrentSession(controller, generation: generation) else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let startupFailure {
            throw StartError.unavailable("系统拒绝：\(startupFailure.domain) \(startupFailure.code)")
        }
        guard isCurrentSession(controller, generation: generation) else {
            throw StartError.unavailable("画中画启动已取消")
        }
        guard controller.isPictureInPictureActive else {
            recordDiagnostic(
                "启动等待超时 possible=\(controller.isPictureInPicturePossible) "
                    + "suspended=\(controller.isPictureInPictureSuspended)"
            )
            stop(notify: false)
            throw StartError.unavailable("等待系统响应超时")
        }
        isActive = true
        // Video-call PiP can become active without delivering the playback-style
        // didStart delegate callback. Confirming active here is therefore a second,
        // authoritative trigger for the observed HomeKitCamera -> VideoCall switch.
        scheduleTypelessControlsStyleTransition(
            for: controller,
            generation: generation
        )
        recordDiagnostic(
            "sample-buffer PiP 待命已启动 geometry=\(Self.frameWidth)x\(Self.frameHeight) "
                + "cadence=\(Self.frameInterval)s rate=\(Self.playbackRate) generation=\(generation)"
        )
    }

    func stop() {
        stop(notify: false)
    }

    private func stop(notify: Bool) {
        let wasActive = isActive
        let controller = pictureInPictureController
        unexpectedStopRecoveryTask?.cancel()
        unexpectedStopRecoveryTask = nil
        isRecoveringUnexpectedSystemStop = false
        sessionGeneration &+= 1
        let invalidatedGeneration = sessionGeneration
        isActive = false
        stopFramePump()
        pictureInPictureController = nil
        requestedGeneration = nil
        controllerGeneration = nil
        startWasRequested = false
        startupFailure = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        pixelBuffer = nil
        formatDescription = nil
        resetTimeline()

        // 下一次用户点击前预建 controller；否则在点击事件内才创建，可能错过用户手势。
        if sourceView?.window != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self,
                      self.sessionGeneration == invalidatedGeneration,
                      !self.startWasRequested,
                      self.pictureInPictureController == nil else { return }
                self.prepareMediaIfNeeded()
                self.prepareControllerIfPossible()
            }
        }
        if wasActive { recordDiagnostic("sample-buffer PiP 待命已结束") }
        if notify { onStopped?() }
    }

    /// Public AVKit only reports a generic didStop. An explicit user stop has
    /// already invalidated/replaced `pictureInPictureController`, so a didStop
    /// from the still-current controller is an unexpected system interruption.
    /// Rebuild inside Pegasus's transient interruption assertion instead of
    /// converting the user's persistent standby request into an off state.
    private func recoverFromUnexpectedSystemStop(
        _ stoppedController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === stoppedController,
              hasValidSession,
              unexpectedStopRecoveryTask == nil else {
            recordDiagnostic("忽略无法恢复的 PiP didStop")
            return
        }

        isActive = false
        isRecoveringUnexpectedSystemStop = true
        stopFramePump()
        pictureInPictureController = nil
        controllerGeneration = nil
        startupFailure = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        requestedGeneration = generation
        startWasRequested = true
        recordDiagnostic(
            "系统意外停止 PiP；进入 interruption assertion 恢复 generation=\(generation)"
        )

        unexpectedStopRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.unexpectedStopRecoveryDelay * 1_000_000_000)
            )
            guard !Task.isCancelled, let self,
                  self.isRecoveringUnexpectedSystemStop,
                  self.requestedGeneration == generation,
                  self.startWasRequested else { return }

            self.prepareMediaIfNeeded()
            self.prepareControllerIfPossible()
            guard let controller = self.pictureInPictureController else {
                self.finishUnexpectedStopRecovery(
                    generation: generation,
                    failure: "controller unavailable"
                )
                return
            }
            self.controllerGeneration = generation
            for _ in 0..<20 {
                if controller.isPictureInPicturePossible { break }
                guard !Task.isCancelled,
                      self.isCurrentSession(controller, generation: generation) else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard controller.isPictureInPicturePossible,
                  self.isCurrentSession(controller, generation: generation) else {
                self.finishUnexpectedStopRecovery(
                    generation: generation,
                    failure: "possible=false"
                )
                return
            }

            self.startFramePump()
            controller.startPictureInPicture()
            self.recordDiagnostic(
                "interruption assertion 内已请求重启 PiP generation=\(generation)"
            )
            let polls = Int(Self.unexpectedStopRecoveryTimeout / 0.05)
            for _ in 0..<polls {
                if controller.isPictureInPictureActive || self.isActive { break }
                guard !Task.isCancelled,
                      self.isCurrentSession(controller, generation: generation) else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard controller.isPictureInPictureActive,
                  self.isCurrentSession(controller, generation: generation) else {
                self.finishUnexpectedStopRecovery(
                    generation: generation,
                    failure: "restart timeout"
                )
                return
            }

            self.isActive = true
            self.isRecoveringUnexpectedSystemStop = false
            self.unexpectedStopRecoveryTask = nil
            self.scheduleTypelessControlsStyleTransition(
                for: controller,
                generation: generation
            )
            self.recordDiagnostic(
                "PiP 系统中断恢复成功 generation=\(generation)"
            )
        }
    }

    private func finishUnexpectedStopRecovery(
        generation: UInt64,
        failure: String
    ) {
        guard requestedGeneration == generation else { return }
        recordDiagnostic(
            "PiP 系统中断恢复失败 generation=\(generation) reason=\(failure)"
        )
        unexpectedStopRecoveryTask = nil
        isRecoveringUnexpectedSystemStop = false
        stop(notify: true)
    }

    private var hasValidSession: Bool {
        guard startWasRequested,
              let generation = requestedGeneration,
              let controller = pictureInPictureController else { return false }
        return isCurrentSession(controller, generation: generation)
    }

    private func isCurrentSession(
        _ controller: AVPictureInPictureController,
        generation: UInt64
    ) -> Bool {
        startWasRequested
            && requestedGeneration == generation
            && controllerGeneration == generation
            && pictureInPictureController === controller
    }

    private func configureTimebase() {
        var created: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &created
        ) == noErr, let created else {
            recordDiagnostic("创建 PiP timebase 失败")
            return
        }
        CMTimebaseSetTime(created, time: .zero)
        CMTimebaseSetRate(created, rate: Self.playbackRate)
        timebase = created
        displayLayer.controlTimebase = created
    }

    private func resetTimeline() {
        nextPresentationTime = .zero
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: Self.playbackRate)
        }
    }

    private func prepareMediaIfNeeded() {
        if pixelBuffer == nil {
            var created: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                Self.frameWidth,
                Self.frameHeight,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &created
            ) == kCVReturnSuccess, let created else {
                recordDiagnostic("创建 PiP pixel buffer 失败")
                return
            }
            clearFrame(created)
            pixelBuffer = created
        }
        if formatDescription == nil, let pixelBuffer {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else {
                recordDiagnostic("创建 PiP format description 失败")
                return
            }
            formatDescription = created
        }
        if nextPresentationTime == .zero {
            if enqueueSingleFrame(at: .zero) {
                nextPresentationTime = Self.frameDuration
            }
        }
    }

    private func clearFrame(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        memset(base, 0, byteCount)
    }

    private func currentMediaTime() -> CMTime {
        guard let timebase else { return .zero }
        return CMTimebaseGetTime(timebase)
    }

    @discardableResult
    private func enqueueSingleFrame(
        at presentationTime: CMTime,
        displayImmediately: Bool = false,
        requireReady: Bool = true
    ) -> Bool {
        let renderer = displayLayer.sampleBufferRenderer
        guard (!requireReady || renderer.isReadyForMoreMediaData),
              let pixelBuffer,
              let formatDescription else { return false }

        var timing = CMSampleTimingInfo(
            duration: Self.frameDuration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return false }
        if displayImmediately,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sampleBuffer,
               createIfNecessary: true
           ) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(sampleBuffer)
        return true
    }

    /// 由 renderer 的 ready 回调一次性补足前置缓冲，而不是把每一帧的及时到达
    /// 寄托在主线程 Timer 上。5040 x 1 BGRA 每帧很小，6 帧缓冲的内存开销有限。
    private func fillBufferedFramesIfPossible() {
        guard hasValidSession, !isRecoveringRenderer else { return }
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.status != .failed else {
            handleRendererFailureIfNeeded()
            return
        }

        let now = currentMediaTime()
        if CMTimeCompare(nextPresentationTime, now) < 0 {
            nextPresentationTime = CMTimeAdd(now, Self.frameDuration)
        }
        let target = CMTimeAdd(now, Self.bufferedMediaLead)
        while renderer.isReadyForMoreMediaData,
              CMTimeCompare(nextPresentationTime, target) <= 0 {
            let pts = nextPresentationTime
            guard enqueueSingleFrame(at: pts) else { break }
            nextPresentationTime = CMTimeAdd(pts, Self.frameDuration)
        }
    }

    private func requestMediaFill() {
        guard hasValidSession,
              !isRecoveringRenderer,
              !isRequestingMediaData else { return }
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.status != .failed else {
            handleRendererFailureIfNeeded()
            return
        }

        isRequestingMediaData = true
        renderer.requestMediaDataWhenReady(on: .main) { [weak self, weak renderer] in
            guard let renderer else { return }
            MainActor.assumeIsolated {
                guard let self else {
                    renderer.stopRequestingMediaData()
                    return
                }
                guard self.isRequestingMediaData else { return }
                self.fillBufferedFramesIfPossible()
                renderer.stopRequestingMediaData()
                self.isRequestingMediaData = false
            }
        }
    }

    private func rendererRecoveryRequirementDidChange() {
        guard hasValidSession else { return }
        let renderer = displayLayer.sampleBufferRenderer
        recordDiagnostic(
            "renderer recovery 状态变化 status=\(renderer.status.rawValue) "
                + "requiresFlush=\(renderer.requiresFlushToResumeDecoding)"
        )
        if renderer.status == .failed {
            handleRendererFailureIfNeeded()
        } else {
            rendererFailureFirstSeenAt = nil
            requestMediaFill()
        }
    }

    private func handleRendererFailureIfNeeded() {
        guard hasValidSession, !isRecoveringRenderer else { return }
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.status == .failed else {
            rendererFailureFirstSeenAt = nil
            return
        }

        let now = Date()
        let firstSeen = rendererFailureFirstSeenAt ?? now
        rendererFailureFirstSeenAt = firstSeen
        let requiresFlush = renderer.requiresFlushToResumeDecoding
        if !requiresFlush, now.timeIntervalSince(firstSeen) < Self.rendererRecoveryGrace {
            scheduleRendererRecoveryCheck()
            return
        }

        beginPreservingRendererRecovery(
            requiresFlush: requiresFlush,
            error: renderer.error
        )
    }

    private func scheduleRendererRecoveryCheck() {
        guard rendererRecoveryTask == nil else { return }
        rendererRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.rendererRecoveryGrace * 1_000_000_000)
            )
            guard let self else { return }
            self.rendererRecoveryTask = nil
            self.handleRendererFailureIfNeeded()
        }
    }

    /// 恢复 decoder 时保留当前 5040 x 1 透明图像，并保持 PTS/timebase 单调。
    /// 这避免普通 flush + 时间轴归零触发 AVKit 重新展示可见的 fallback surface。
    private func beginPreservingRendererRecovery(
        requiresFlush: Bool,
        error: Error?
    ) {
        guard !isRecoveringRenderer else { return }
        let renderer = displayLayer.sampleBufferRenderer
        isRecoveringRenderer = true
        rendererRecoveryTask?.cancel()
        rendererRecoveryTask = nil
        if isRequestingMediaData {
            renderer.stopRequestingMediaData()
            isRequestingMediaData = false
        }
        let generation = requestedGeneration
        let timeBeforeFlush = currentMediaTime()
        let nextPTSBeforeFlush = nextPresentationTime
        recordDiagnostic(
            "renderer preserving recovery begin requiresFlush=\(requiresFlush) "
                + "error=\(error?.localizedDescription ?? "unknown") "
                + "mediaTime=\(CMTimeGetSeconds(timeBeforeFlush)) "
                + "nextPTS=\(CMTimeGetSeconds(nextPTSBeforeFlush))"
        )

        renderer.flush(removingDisplayedImage: false) { [weak self, weak renderer] in
            Task { @MainActor [weak self, weak renderer] in
                guard let self, let renderer else { return }
                guard self.requestedGeneration == generation,
                      self.hasValidSession else {
                    self.isRecoveringRenderer = false
                    return
                }
                let now = self.currentMediaTime()
                // flush 已丢弃此前排在未来的 sample buffers。若继续沿用 flush 前的
                // nextPTS，renderer 会在数秒内没有新图像，AVKit 可能先用可见的
                // fallback surface 重新布局。这里以当前 timebase 立即重新播种一帧
                // 5040 x 1 图像；单帧有界 enqueue 即使 ready 暂为 false 也安全。
                let reseeded = self.enqueueSingleFrame(
                    at: now,
                    displayImmediately: true,
                    requireReady: false
                )
                self.nextPresentationTime = CMTimeAdd(now, Self.frameDuration)
                self.isRecoveringRenderer = false
                self.rendererFailureFirstSeenAt = nil
                self.pictureInPictureController?.invalidatePlaybackState()
                self.recordDiagnostic(
                    "renderer preserving recovery complete status=\(renderer.status.rawValue) "
                        + "requiresFlush=\(renderer.requiresFlushToResumeDecoding) "
                        + "immediateReseed=\(reseeded) "
                        + "mediaTime=\(CMTimeGetSeconds(now)) "
                        + "nextPTS=\(CMTimeGetSeconds(self.nextPresentationTime))"
                )
                self.requestMediaFill()
            }
        }
    }

    private func startFramePump() {
        guard hasValidSession else { return }
        prepareMediaIfNeeded()
        if frameTimer != nil { return }
        requestMediaFill()
        let timer = DispatchSource.makeTimerSource(queue: mediaFeederQueue)
        timer.schedule(
            deadline: .now() + Self.frameInterval,
            repeating: Self.frameInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestMediaFill()
            }
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopFramePump() {
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        frameTimer = nil
        rendererRecoveryTask?.cancel()
        rendererRecoveryTask = nil
        controlsStyleTransitionTask?.cancel()
        controlsStyleTransitionTask = nil
        rendererFailureFirstSeenAt = nil
        isRecoveringRenderer = false
        if isRequestingMediaData {
            displayLayer.sampleBufferRenderer.stopRequestingMediaData()
            isRequestingMediaData = false
        }
    }

    /// 待命偏好。`@AppStorage("standbyPreferredOn")` 的默认值是 **true**,而
    /// `UserDefaults.bool(forKey:)` 对未写入的键返回 false —— 必须显式区分"没写过"和"写了 false"。
    private var standbyPreferred: Bool {
        UserDefaults.standard.object(forKey: "standbyPreferredOn") as? Bool ?? true
    }

    /// ⚠️ 只在用户确实要用待命时才创建控制器。
    ///
    /// 原来这里是**无条件**创建的(根视图 `attachSource` 一挂载就建),于是即使用户关掉了
    /// 「免切换待命」,App 里依然常驻一个 hosted video-call 的 `AVPictureInPictureController`,
    /// 而且施加了私有的 HomeKitCamera 控件样式。2026-08-08 排查灵动岛常驻不显示时,这是
    /// 我们与对照工程 LAProbe(常驻正常)之间**最后一项**未排除的差异 —— 关待命之所以看不出
    /// 效果,正是因为关的只是 `startPictureInPicture()`,控制器照样建。
    private func prepareControllerIfPossible() {
        guard standbyPreferred else {
            recordDiagnostic("待命偏好为关,不创建 PiP 控制器")
            return
        }
        guard pictureInPictureController == nil,
              AVPictureInPictureController.isPictureInPictureSupported(),
              let sourceView,
              formatDescription != nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallContentViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = true
        let appliedHomeKitStyle = applyPrivateControlsStyle(
            Self.homeKitCameraControlsStyle,
            to: controller
        )
        pictureInPictureController = controller
        controllerGeneration = nil
        recordDiagnostic(
            "已创建 hosted-video-call PiP controller possible=\(controller.isPictureInPicturePossible) "
                + "controlsStyle=HomeKitCamera(3) applied=\(appliedHomeKitStyle)"
        )
        recordControlsStyleDiagnostic(
            "HomeKitCamera(3) applied=\(appliedHomeKitStyle) source=hostedVideoCall"
        )
    }

    /// AVPictureInPictureController 内部仍实现 setControlsStyle: 并将其转发给
    /// Pegasus proxy。用 runtime 核对 selector 后调用，避免 KVC 在系统删除
    /// 该属性时抛出无法捕获的 Objective-C exception。
    @discardableResult
    private func applyPrivateControlsStyle(
        _ style: Int,
        to controller: AVPictureInPictureController
    ) -> Bool {
        let selector = NSSelectorFromString("setControlsStyle:")
        guard controller.responds(to: selector),
              let method = class_getInstanceMethod(type(of: controller), selector) else {
            return false
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(controller, selector, style)
        return true
    }

    private func scheduleTypelessControlsStyleTransition(
        for controller: AVPictureInPictureController,
        generation: UInt64
    ) {
        controlsStyleTransitionTask?.cancel()
        controlsStyleTransitionTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.controlsStyleTransitionDelay * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  let controller,
                  self.isCurrentSession(controller, generation: generation),
                  controller.isPictureInPictureActive else { return }
            let applied = self.applyPrivateControlsStyle(
                Self.videoCallControlsStyle,
                to: controller
            )
            self.controlsStyleTransitionTask = nil
            self.recordDiagnostic(
                "Typeless controlsStyle transition HomeKitCamera(3)->VideoCall(4) "
                    + "applied=\(applied) generation=\(generation)"
            )
            self.recordControlsStyleDiagnostic(
                "HomeKitCamera(3)->VideoCall(4) applied=\(applied) "
                    + "generation=\(generation) source=hostedVideoCall"
            )
        }
    }

    private func recordControlsStyleDiagnostic(_ message: String) {
        AppGroup.suite?.set(
            "\(Date().timeIntervalSince1970)|\(message)",
            forKey: "lastPiPControlsStyleDiagnostic"
        )
    }

    private func recordDiagnostic(_ message: String) {
        print("[SWT PiP] \(message)")
        os_log("%{public}@", log: Self.log, type: .info, message)
        DiagLog.log("pip", message)
        AppGroup.suite?.set(
            "\(Date().timeIntervalSince1970)|\(message)",
            forKey: "lastPiPDiagnostic"
        )
    }
}

extension PictureInPictureStandbyController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let generation = controllerGeneration,
              isCurrentSession(pictureInPictureController, generation: generation) else {
            recordDiagnostic("忽略过期 PiP didStart；停止旧 controller")
            if pictureInPictureController.isPictureInPictureActive {
                pictureInPictureController.stopPictureInPicture()
            }
            return
        }
        isActive = true
        startFramePump()
        scheduleTypelessControlsStyleTransition(
            for: pictureInPictureController,
            generation: generation
        )
        recordDiagnostic("sample-buffer PiP 已进入 active generation=\(generation)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let nsError = error as NSError
        guard let generation = controllerGeneration,
              isCurrentSession(pictureInPictureController, generation: generation) else {
            recordDiagnostic(
                "忽略过期 PiP 启动失败回调 domain=\(nsError.domain) code=\(nsError.code)"
            )
            return
        }
        startupFailure = nsError
        recordDiagnostic(
            "sample-buffer PiP 启动失败 domain=\(nsError.domain) code=\(nsError.code) "
                + "message=\(error.localizedDescription)"
        )
        stop(notify: true)
        // stop() 会清理状态；保留本次错误，使正在等待的 start() 立即退出。
        startupFailure = nsError
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard self.pictureInPictureController === pictureInPictureController else {
            recordDiagnostic("忽略过期 PiP didStop")
            return
        }
        recoverFromUnexpectedSystemStop(pictureInPictureController)
    }
}

extension PictureInPictureStandbyController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 待命画面是 live 内容，不提供暂停态。
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        recordDiagnostic(
            "PiP render size transition width=\(newRenderSize.width) height=\(newRenderSize.height)"
        )
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        completion()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { true }
}
