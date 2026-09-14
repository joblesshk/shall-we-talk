import Foundation
import AVFoundation
import Combine
import UIKit
import ShallWeTalkCore

/// 会议录音的完整生命周期:多段录制 + 中断自动续录 + 端侧草稿转写 + 会后权威转写 + 摘要生成。
///
/// 与 `DictationController` 刻意分开(不是往那个 2400 行的单结果状态机里加分支):
/// 会议是 `idle → recording ⇄ pausedByInterruption → finalizing → summarizing` 的多段长会话,
/// 而 `DictationController` 是"一次口述、一个结果"的短会话,VAD 自动停/增量整理/待办路由
/// 这些逻辑对会议全部不适用。两者只共享 `Recorder` 这一个类型,通过
/// `yieldAudioForMeeting`/`reclaimAudioAfterMeeting` 互斥 `AVAudioSession` 的使用权。
@MainActor
final class MeetingRecordingController: ObservableObject {
    static let shared = MeetingRecordingController()

    enum Phase: Equatable {
        case idle
        /// 点击开始后立即进入这个态，而不是等待 AVAudioEngine 建好才显示录音界面。
        /// 这段很短的建连窗口也属于一场已经被用户确认开始的会议，必须禁止第二次点击
        /// 再创建一场记录。
        case starting
        case recording
        /// 来电/其它 App 抢麦导致暂停。`shouldResume` 为 true 时会自动续录;
        /// 为 false 或续录失败时停留在这个态,等用户手动点"继续录音"。
        case pausedByInterruption
        /// 用户点了"结束会议",最后一段正在收尾(写文件/关闭 writer)。
        case finalizing
    }

    let store = MeetingStore()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var livePartial: String = ""
    /// 当前会议已经产出的端侧草稿。`livePartial` 只保留最近一句给紧凑控件使用；
    /// 专用录音页展示这个完整的、持续增长的文本，避免用户只能看到最后两行。
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var statusNote: String?

    var isActive: Bool { phase != .idle }

    private var settings: MobileSettingsStore { DictationController.shared.settings }

    /// `store` 是嵌套的 ObservableObject，其 meetings 变更不会自动通知
    /// 只观察本控制器的会议列表/详情页。统一转发后，删除会议会立即从界面消失。
    private var storeChangeForwarder: AnyCancellable?

    private let recorder = Recorder()
    private var audioWriter: MeetingAudioWriter?
    private let captioner = MeetingLiveCaptioner()
    private var currentSegmentID: UUID?
    private var meetingStartedAt: Date?
    private var interruptionBeganAt: Date?

    private var elapsedTimer: Timer?
    private var stallWatchdog: Timer?
    private var rotationTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    private var isTransitioningSegment = false
    private var lastPhysicalRouteRecoveryAt = Date.distantPast
    private var lastCapturedByteCountForStall = 0
    private var staleStallTicks = 0

    /// 与 `DictationController` 那条 1.5 秒的"陈旧中断不续录"窗口不同:那是为了不让一次
    /// 已经放弃的键盘口述被意外唤醒;会议是用户显式发起的长会话,一通 40 分钟的电话
    /// 结束后仍然应该自动续录,所以给一个宽得多的窗口。
    private static let staleInterruptionResumeWindow: TimeInterval = 10 * 60
    /// 长会议主动分段:界定单条 ASR/写盘连接的暴露时间上限,也让崩溃最多丢 20 分钟。
    private static let rotationInterval: TimeInterval = 20 * 60

    @Published private(set) var isCloudSyncing = false
    @Published private(set) var lastCloudSyncStatus = "未同步"

    private init() {
        storeChangeForwarder = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        captioner.onDraftUtterance = { [weak self] segmentID, utterance in
            Task { @MainActor in self?.ingestDraftUtterance(utterance, segmentID: segmentID) }
        }
        startAudioObservers()
        // 与 DictationController 对历史记录的既有节奏一致:启动后延迟拉取一次 iCloud,
        // 避开冷启动最初几秒的资源争抢。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.syncFromCloud()
        }
    }

    // MARK: - iCloud 同步(全部同步:标题/摘要/逐字稿,音频永不上云)

    func syncFromCloud() {
        guard settings.iCloudSyncEnabled else { lastCloudSyncStatus = "iCloud 同步未开启"; return }
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        lastCloudSyncStatus = "正在检查 iCloud…"
        let local = store.meetings
        let localDeletions = store.deletionTombstones
        let pendingDeletions = store.pendingDeletionTombstones
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> CloudMeetingSync.PullResult? in
                guard CloudMeetingSync.isAvailable else { return nil }
                guard let pull = CloudMeetingSync.pull(into: local, localDeletions: localDeletions) else { return nil }
                _ = CloudMeetingSync.pushAll([], deletions: pendingDeletions)
                return pull
            }.value
            guard let self else { return }
            self.isCloudSyncing = false
            guard let pull = result else { self.lastCloudSyncStatus = "iCloud 不可用"; return }
            self.store.applyCloudMerge(records: pull.merged, deletions: pull.deletions)
            var parts: [String] = []
            if pull.inserted > 0 { parts.append("新增 \(pull.inserted) 场") }
            if pull.updated > 0 { parts.append("更新 \(pull.updated) 场") }
            if pull.removed > 0 { parts.append("删除 \(pull.removed) 场") }
            self.lastCloudSyncStatus = parts.isEmpty ? "已检查 iCloud,暂无新内容" : "已从 iCloud " + parts.joined(separator: " · ")
        }
    }

    func syncToCloud() {
        guard settings.iCloudSyncEnabled else { lastCloudSyncStatus = "iCloud 同步未开启"; return }
        guard !isCloudSyncing else { return }
        isCloudSyncing = true
        lastCloudSyncStatus = "正在上传到 iCloud…"
        let records = store.meetings
        let deletions = store.pendingDeletionTombstones
        Task { [weak self] in
            let push = await Task.detached(priority: .utility) { () -> CloudMeetingSync.PushResult? in
                guard CloudMeetingSync.isAvailable else { return nil }
                return CloudMeetingSync.pushAll(records, deletions: deletions)
            }.value
            guard let self else { return }
            self.isCloudSyncing = false
            if let push, push.succeeded {
                self.lastCloudSyncStatus = "已上传 \(records.count) 场会议到 iCloud"
            } else if push != nil {
                self.lastCloudSyncStatus = "部分记录上传失败"
            } else {
                self.lastCloudSyncStatus = "iCloud 不可用"
            }
        }
    }

    // MARK: - 开始 / 结束

    /// Shortcut toggle shares the same meeting lifecycle as the on-screen controls.
    /// Check stop before any suspension so a second invocation cannot create a new meeting.
    func toggleFromShortcut() async throws -> String {
        switch phase {
        case .starting, .recording, .pausedByInterruption:
            stop()
            return "会议录音已停止，正在保存和整理"
        case .finalizing:
            return "正在结束会议，请稍候"
        case .idle:
            break
        }
        guard DictationController.shared.phase != .recording,
              DictationController.shared.phase != .processing else {
            throw NSError(domain: "MeetingShortcut", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先结束当前语音输入，再开始会议录音。"])
        }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard allowed else {
            throw NSError(domain: "MeetingShortcut", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "请在系统设置中允许 Shall We Talk 使用麦克风。"])
        }
        // Another invocation or the on-screen button may have started while permission was pending.
        guard phase == .idle else { return "会议录音已在进行中" }
        start()
        guard let meetingID = activeMeetingID else {
            throw NSError(domain: "MeetingShortcut", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "会议录音未能启动，请检查当前录音状态。"])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            guard activeMeetingID == meetingID else {
                if store.meetings.first(where: { $0.id == meetingID })?.state == .failed {
                    throw NSError(domain: "MeetingShortcut", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "会议录音启动失败，请在会议记录中查看原因。"])
                }
                return "本次会议录音已结束"
            }
            if phase == .recording && recorder.capturedByteCount > 0 {
                return "会议录音已开始"
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if activeMeetingID == meetingID { stop() }
        throw NSError(domain: "MeetingShortcut", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "会议录音未收到音频，已停止；请检查麦克风后重试。"])
    }

    func start() {
        guard phase == .idle else { return }
        guard DictationController.shared.phase != .recording,
              DictationController.shared.phase != .processing else {
            DiagLog.log("meeting", "拒绝开始会议:口述正在进行")
            return
        }
        // 必须在任何 await/Task 之前锁住会议状态。此前 phase 要等 `openSegment` 完成后
        // 才变成 `.recording`，用户在该窗口再点一次会并发创建第二条会议并覆盖音频回调。
        phase = .starting
        statusNote = "正在准备录音…"
        livePartial = ""
        liveTranscript = ""
        DictationController.shared.yieldAudioForMeeting()
        let record = store.beginMeeting(speakerInfoEnabled: settings.meetingSpeakerDiarization)
        activeMeetingID = record.id
        meetingStartedAt = record.startedAt
        captioner.reset()
        openingTask = Task { [weak self] in
            await self?.openSegment(index: 0)
        }
        startElapsedTimer()
        scheduleRotation()
    }

    func stop() {
        guard phase == .starting || phase == .recording || phase == .pausedByInterruption else { return }
        guard let meetingID = activeMeetingID else { return }
        phase = .finalizing
        statusNote = "正在结束会议…"
        openingTask?.cancel()
        openingTask = nil
        stopElapsedTimer()
        stopStallWatchdog()
        rotationTask?.cancel(); rotationTask = nil
        if currentSegmentID != nil {
            closeCurrentSegment(reason: .manualStop, resolved: true)
        } else {
            // 录音引擎尚在起录时用户已经选择结束；这个 Recorder 属于会议控制器，
            // 可以安全完整拆掉，不能让稍后返回的起录任务遗留一个无主的 tap。
            recorder.teardown()
        }
        store.endMeeting(id: meetingID, endedAt: Date())
        phase = .idle
        activeMeetingID = nil
        meetingStartedAt = nil
        livePartial = ""
        liveTranscript = ""
        statusNote = nil
        DictationController.shared.reclaimAudioAfterMeeting()
        pushToCloudIfEnabled(meetingID: meetingID)
        // 先封存一份完整 WAV，再允许任何网络识别或 LLM 整理开始。封存失败不会删除原始
        // 分段，后续仍可从详情页再次尝试导出/合成；识别任务也不拥有删除音频的权限。
        Task {
            await sealCompleteAudioArchive(meetingID: meetingID)
            await finalizeTranscriptAndSummary(meetingID: meetingID)
        }
    }

    /// 中断结束但系统未允许自动续录(`shouldResume == false`)时,留在 `.pausedByInterruption`
    /// 等用户看到"继续录音"按钮主动点——而不是替用户默默结束会议。
    func resumeRecording() {
        guard phase == .pausedByInterruption, let meetingID = activeMeetingID else { return }
        let nextIndex = store.meetings.first(where: { $0.id == meetingID })?.segments.count ?? 0
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DiagLog.log("meeting", "手动续录激活会话失败: \(error.localizedDescription)")
            statusNote = "无法恢复录音，请重试或结束会议"
            return
        }
        Task { await openSegment(index: nextIndex) }
    }

    // MARK: - 段落开关

    private func openSegment(index: Int) async {
        guard let meetingID = activeMeetingID, phase != .idle, phase != .finalizing,
              currentSegmentID == nil else { return }
        let startedAt = Date()
        let audioName = "\(meetingID.uuidString)-\(index).wav"
        // 文件名是 crash-recovery 的索引，必须与未闭合 segment 一起先落库，不能等 close()。
        let segment = MeetingSegment(index: index, startedAt: startedAt, audioFileName: audioName)
        store.appendSegment(meetingID: meetingID, segment: segment)
        currentSegmentID = segment.id
        captioner.reset(segmentID: segment.id)

        do {
            audioWriter = try MeetingAudioWriter(url: store.audioURL(for: audioName))
        } catch {
            // 音频存档是会议功能的第一优先级。没有已打开的落盘文件时绝不能继续起录，
            // 否则 UI 看似在录，识别失败后却没有任何原始材料可救。
            DiagLog.log("meeting", "拒绝起录：无法创建段落音频文件: \(error.localizedDescription)")
            store.closeSegment(meetingID: meetingID, segmentID: segment.id, endedAt: Date(),
                               audioFileName: nil, reason: .asrFailure, resolved: false)
            currentSegmentID = nil
            failMeetingStart(meetingID: meetingID, error: error)
            return
        }

        recorder.retainsPCM = false
        recorder.onChunk = { [weak self] data in
            self?.audioWriter?.append(data)
            self?.captioner.feed(data)
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }

        do {
            try await startRecorderWithColdRetry()
        } catch {
            DiagLog.log("meeting", "会议录音起录失败: \(error.localizedDescription)")
            let audioURL = audioWriter?.close()
            store.closeSegment(meetingID: meetingID, segmentID: segment.id, endedAt: Date(),
                               audioFileName: audioURL?.lastPathComponent,
                               reason: .asrFailure, resolved: false)
            audioWriter = nil
            currentSegmentID = nil
            failMeetingStart(meetingID: meetingID, error: error)
            return
        }
        // `stop()` 或另一个生命周期事件可能在 await 期间结束了这场会议。不要让
        // 已经失效的起录任务重新把 UI 置回 recording 或接管新的音频文件。
        guard !Task.isCancelled, activeMeetingID == meetingID, phase != .finalizing else {
            recorder.teardown()
            return
        }
        phase = .recording
        statusNote = "录音中"
        lastCapturedByteCountForStall = 0
        staleStallTicks = 0
        openingTask = nil
        startStallWatchdog()
    }

    private func failMeetingStart(meetingID: UUID, error: Error) {
        guard activeMeetingID == meetingID else { return }
        openingTask = nil
        stopElapsedTimer()
        stopStallWatchdog()
        rotationTask?.cancel(); rotationTask = nil
        store.endMeeting(id: meetingID, endedAt: Date())
        store.setState(id: meetingID, .failed, lastError: "无法开始录音：\(error.localizedDescription)")
        activeMeetingID = nil
        meetingStartedAt = nil
        livePartial = ""
        liveTranscript = ""
        phase = .idle
        statusNote = nil
        DictationController.shared.reclaimAudioAfterMeeting()
    }

    /// 与 `DictationController.startRecorderWithColdRetry` 同样的一次性瞬时失败重试
    /// (输入路由未就绪 / `'!int'` 被别的音频 App 短暂占用),独立一份而不是抽公共函数——
    /// 会议这条路径不需要"热直通"分支,合并会引入不必要的耦合。
    private func startRecorderWithColdRetry() async throws {
        do {
            try recorder.start()
        } catch let e as NSError where Self.isTransientColdStartError(e) {
            DiagLog.log("meeting", "冷激活瞬时失败,退会话后 250ms 重试一次: \(e.domain) \(e.code)")
            recorder.teardown()
            try? await Task.sleep(nanoseconds: 250_000_000)
            try recorder.start()
        }
    }

    private static func isTransientColdStartError(_ e: NSError) -> Bool {
        if e.domain == "Recorder" { return true }
        if e.code == 560_557_684 { return true }  // '!int' cannotInterruptOthers
        if e.code == -10868 { return true }       // kAudioUnitErr_FormatNotSupported
        return false
    }

    /// 关闭当前段落:停引擎、关文件写入器、把结果写回 store。会议模式下不需要像
    /// `DictationController.stopForInterruption` 那样"冲刷 ASR 收尾"——权威转写来自
    /// 会后重新识别整段音频文件,只要音频已经落盘(`MeetingAudioWriter.append` 在
    /// `onChunk` 里无条件调用,不受草稿转写影响),这一段就不会丢失任何内容。
    private func closeCurrentSegment(reason: MeetingSegmentEndReason, resolved: Bool) {
        guard let meetingID = activeMeetingID, let segmentID = currentSegmentID else { return }
        recorder.onChunk = nil
        recorder.onLevel = nil
        _ = recorder.stop()
        captioner.flush()
        let audioURL = audioWriter?.close()
        store.closeSegment(meetingID: meetingID, segmentID: segmentID, endedAt: Date(),
                           audioFileName: audioURL?.lastPathComponent, reason: reason,
                           resolved: resolved && audioURL != nil)
        audioWriter = nil
        currentSegmentID = nil
        audioLevel = 0
    }

    /// 合成工作在后台串行 I/O 上执行，避免长会议的数百 MB WAV 合并阻塞录音 UI。
    /// 无论合成成功与否，源分段都保留，失败仅写诊断并允许用户手动再次导出。
    private func sealCompleteAudioArchive(meetingID: UUID) async {
        do {
            let plan = try store.completeAudioArchivePlan(for: meetingID)
            _ = try await Task.detached(priority: .utility) {
                try MeetingAudioWriter.combineWAVSegments(plan.sourceURLs, to: plan.destination)
            }.value
        } catch {
            DiagLog.log("meeting", "完整录音合并失败（原始分段已保留）: \(error.localizedDescription)")
        }
    }

    /// 详情页“导出完整录音”的统一入口。若停止时的自动封存因系统资源不足失败，
    /// 此处会根据仍被保留的原始分段重试一次。
    func completeAudioArchiveForExport(meetingID: UUID) async throws -> URL {
        let plan = try store.completeAudioArchivePlan(for: meetingID)
        if FileManager.default.fileExists(atPath: plan.destination.path) {
            let size = (try? plan.destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 44 { return plan.destination }
        }
        return try await Task.detached(priority: .utility) {
            try MeetingAudioWriter.combineWAVSegments(plan.sourceURLs, to: plan.destination)
            return plan.destination
        }.value
    }

    private func rotateSegment(reason: MeetingSegmentEndReason) async {
        guard phase == .recording, let meetingID = activeMeetingID, !isTransitioningSegment else { return }
        isTransitioningSegment = true
        defer { isTransitioningSegment = false }
        let nextIndex = store.meetings.first(where: { $0.id == meetingID })?.segments.count ?? 0
        closeCurrentSegment(reason: reason, resolved: true)
        await openSegment(index: nextIndex)
    }

    // MARK: - 中断 / 路由变化

    private func startAudioObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            guard phase == .recording else { return }
            DiagLog.log("meeting", "会议录音因中断暂停")
            interruptionBeganAt = Date()
            phase = .pausedByInterruption
            statusNote = "通话中已暂停，通话结束后自动续录"
            closeCurrentSegment(reason: .interruption, resolved: true)
        case .ended:
            guard phase == .pausedByInterruption else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            let age = interruptionBeganAt.map { Date().timeIntervalSince($0) } ?? 0
            interruptionBeganAt = nil
            DiagLog.log("meeting", "中断结束 shouldResume=\(shouldResume) age=\(String(format: "%.1f", age))s")
            guard shouldResume else {
                statusNote = "通话已结束，请点击继续录音"
                return
            }
            guard age <= Self.staleInterruptionResumeWindow else {
                statusNote = "中断时间较长，请点击继续录音"
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                DiagLog.log("meeting", "中断后重新激活会话失败: \(error.localizedDescription)")
                statusNote = "请点击继续录音"
                return
            }
            let meetingID = activeMeetingID
            let nextIndex = meetingID.flatMap { id in store.meetings.first(where: { $0.id == id })?.segments.count } ?? 0
            Task { await openSegment(index: nextIndex) }
        @unknown default: break
        }
    }

    /// 只对物理输入设备插拔作恢复。`.categoryChange` 与 `.override` 会在本控制器调用
    /// `configureAudioSession` 时由系统自身发出；旧代码将它们也当作耳机切换，形成
    /// "起录 → 收到自身路由通知 → 轮转 → 再起录"的自激循环，实际产生大量 44B WAV。
    /// 真正的耳机/蓝牙切换仍以一次受限的段落轮转恢复 Audio Engine 绑定。
    private func handleRouteChange(_ note: Notification) {
        guard phase == .recording else { return }
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else {
            DiagLog.log("meeting", "忽略会话内部路由变化 reason=\(reasonValue)")
            return
        }
        // 一次插拔通常会连续送达 old/new 两个通知；它们只应触发一次重建。
        guard Date().timeIntervalSince(lastPhysicalRouteRecoveryAt) >= 1 else { return }
        lastPhysicalRouteRecoveryAt = Date()
        DiagLog.log("meeting", "物理音频路由变化 reason=\(reasonValue),轮转分段以重建引擎")
        Task { await rotateSegment(reason: .routeChange) }
    }

    // MARK: - 看门狗 / 主动轮转 / 计时

    private func startStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStall() }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = nil
    }

    /// "引擎起来了但系统一个样本都不给"的自愈:与 `Recorder.capturedByteCount` 文档
    /// 描述的后台开麦黑洞是同一失败模式,会议场景下必须自愈而不是录一小时静音。
    private func checkStall() {
        guard phase == .recording else { return }
        let current = recorder.capturedByteCount
        if current == lastCapturedByteCountForStall {
            staleStallTicks += 1
            if staleStallTicks >= 3 {
                staleStallTicks = 0
                DiagLog.log("meeting", "录音黑洞看门狗触发,轮转分段")
                Task { await rotateSegment(reason: .audioStall) }
            }
        } else {
            staleStallTicks = 0
        }
        lastCapturedByteCountForStall = current
    }

    private func scheduleRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.rotationInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.rotateSegment(reason: .rotation)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.meetingStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsed = 0
    }

    private func ingestDraftUtterance(_ utterance: MeetingUtterance, segmentID: UUID) {
        guard let meetingID = activeMeetingID,
              store.meetings.first(where: { $0.id == meetingID })?.segments.contains(where: { $0.id == segmentID }) == true
        else { return }
        store.appendUtterance(meetingID: meetingID, segmentID: segmentID, utterance)
        livePartial = utterance.text
        liveTranscript = liveTranscript.isEmpty ? utterance.text : liveTranscript + "\n\n" + utterance.text
    }

    // MARK: - 会后处理:权威转写 → 摘要

    /// 用极速版录音文件识别替换每一段的端侧草稿,再触发摘要生成。极速版同步返回结果、
    /// 支持内联 base64 WAV,不需要公网 URL 或临时对象存储。每段约 20 分钟，远低于其
    /// 100MB/2 小时单请求限制；完整合并 WAV 只用于用户保存、导出与未来重新识别。
    /// 任一段失败都不阻塞其它段，且任何失败均不删除本机完整 WAV 或分段原件。
    func finalizeTranscriptAndSummary(meetingID: UUID) async {
        store.setState(id: meetingID, .finalizingTranscript)
        guard let record = store.meetings.first(where: { $0.id == meetingID }) else { return }
        var anyFailure = false
        var hasUsableAudio = false
        for segment in record.segments.sorted(by: { $0.index < $1.index }) {
            guard let audioName = segment.audioFileName else {
                anyFailure = true
                DiagLog.log("meeting", "极速版最终转写跳过 segment=\(segment.index): 缺少音频文件名")
                continue
            }
            guard let wav = try? Data(contentsOf: store.audioURL(for: audioName)), wav.count > 44 else {
                anyFailure = true
                DiagLog.log("meeting", "极速版最终转写跳过 segment=\(segment.index): WAV 不可读取或没有 PCM")
                continue
            }
            hasUsableAudio = true
            do {
                try await settings.prepareRelaySession()
                let result = try await VolcFileTranscription.transcribe(
                    wav: wav,
                    appId: settings.usesWorkerRelay ? "" : settings.volcAppId,
                    accessToken: settings.usesWorkerRelay ? "" : settings.volcAccessToken,
                    resourceId: settings.volcFileResourceId, enableSpeakerInfo: record.speakerInfoEnabled,
                    hotwordsContext: settings.hotwordsContext, outputChineseVariant: settings.outputChineseVariant,
                    endpoint: settings.usesWorkerRelay ? settings.workerRelayFileURL : nil,
                    bearerToken: settings.usesWorkerRelay ? settings.activeWorkerToken : nil)
                var utterances = result.utterances.map {
                    MeetingUtterance(text: $0.text, startMs: $0.startMs, endMs: $0.endMs,
                                     speakerID: $0.speakerID, isFinal: true)
                }
                if utterances.isEmpty, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    utterances = [MeetingUtterance(text: result.text, startMs: 0, endMs: 0, isFinal: true)]
                }
                guard !utterances.isEmpty else {
                    throw NSError(domain: "MeetingTranscription", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "极速版录音文件识别返回空文本"])
                }
                guard store.replaceTranscript(meetingID: meetingID, segmentID: segment.id, utterances: utterances) else {
                    throw NSError(domain: "MeetingTranscription", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "会议片段已变化，未覆盖当前记录，请重新转写"])
                }
            } catch {
                anyFailure = true
                DiagLog.log("meeting", "极速版最终转写失败 segment=\(segment.index): \(error.localizedDescription)")
            }
        }
        guard hasUsableAudio else {
            store.setState(id: meetingID, .failed,
                           lastError: "没有采集到可转写的音频；本次会议已停止，未生成文字。")
            return
        }
        if anyFailure {
            store.setState(id: meetingID, .needsFinalize,
                           lastError: "部分片段的极速版高精度转写失败；原始录音已保留，可稍后重新转写并生成纪要。")
            pushToCloudIfEnabled(meetingID: meetingID)
            return
        }
        store.setState(id: meetingID, .transcribed)
        // 权威转写是独立成果；摘要失败不能阻止它同步到其它设备。
        pushToCloudIfEnabled(meetingID: meetingID)
        await generateSummary(meetingID: meetingID)
    }

    /// 供"补生成"/"重试"入口统一调用:还没有权威转写就先补转写,已经有就直接重新摘要。
    func finalizeIfNeeded(meetingID: UUID) {
        guard let record = store.meetings.first(where: { $0.id == meetingID }) else { return }
        Task {
            // 一场会议可能只有部分片段识别成功，`isFinalTranscript` 会为 true；此时仍必须
            // 依据 `.needsFinalize` 重跑文件识别，不能误把“补救转写”降级成只生成摘要。
            if !record.isFinalTranscript || record.state == .needsFinalize || record.state == .failed {
                await finalizeTranscriptAndSummary(meetingID: meetingID)
            } else {
                await generateSummary(meetingID: meetingID)
            }
        }
    }

    /// 用户手动编辑转写后点"重新生成摘要"的入口。
    func regenerateSummary(meetingID: UUID) {
        Task { await generateSummary(meetingID: meetingID) }
    }

    func saveEditedTranscript(meetingID: UUID, text: String) {
        store.setEditedTranscript(id: meetingID, text: text)
        pushToCloudIfEnabled(meetingID: meetingID)
    }

    /// 会议删除没有撤销入口，本地文字/音频删除成功后立即把墓碑推上云；
    /// 墓碑也会持久化在本机，无网或上传失败时由后续同步重试。
    @discardableResult
    func delete(meetingID: UUID) -> Bool {
        guard let record = store.meetings.first(where: { $0.id == meetingID }) else { return false }
        guard store.delete(id: meetingID) else { return false }
        guard settings.iCloudSyncEnabled else { return true }
        guard let deletedAt = store.deletionTombstones[meetingID] else { return true }
        Task.detached(priority: .utility) {
            _ = CloudMeetingSync.pushDeletion(id: meetingID, createdAt: record.createdAt, deletedAt: deletedAt)
        }
        return true
    }

    private func generateSummary(meetingID: UUID) async {
        guard let record = store.meetings.first(where: { $0.id == meetingID }) else { return }
        store.setState(id: meetingID, .summarizing)
        let transcript = record.editedTranscriptText
            ?? MeetingTranscript.promptText(segments: record.segments, meetingStartedAt: record.startedAt)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.setState(id: meetingID, .transcribed, lastError: "转写内容为空，无法生成摘要")
            return
        }
        let hasGaps = record.segments.contains {
            guard let reason = $0.endReason else { return false }
            return reason != .manualStop && reason != .rotation
        }
        let duration = record.endedAt.map { $0.timeIntervalSince(record.startedAt) }
            ?? MeetingTranscript.totalSpeechDuration(record.segments)
        do {
            try await settings.prepareRelaySession()
            let raw = try await summarize(transcript: transcript, startedAt: record.startedAt,
                                          duration: duration, hasGaps: hasGaps)
            let parsed = MeetingSummaryParser.parse(raw)
            store.setSummary(id: meetingID, summary: parsed, raw: raw)
            pushToCloudIfEnabled(meetingID: meetingID)
        } catch {
            store.setState(id: meetingID, .transcribed, lastError: "生成摘要失败: \(error.localizedDescription)")
            pushToCloudIfEnabled(meetingID: meetingID)
        }
    }

    /// 单条记录的后台推送(不弹状态、不影响 `isCloudSyncing`),与 `DictationController`
    /// 对每条新历史记录的既有做法一致——不必等用户手动点"同步"才把新内容带上云。
    private func pushToCloudIfEnabled(meetingID: UUID) {
        guard settings.iCloudSyncEnabled, let record = store.meetings.first(where: { $0.id == meetingID }) else { return }
        Task.detached(priority: .utility) { _ = CloudMeetingSync.push(record) }
    }

    /// 摘要固定用 DeepSeek(2026-08-20 用户明确要求"用 DeepSeek Flash 来形成"),不跟随
    /// 用户为口述整理选的供应商——那个可能切到方舟或自定义端点,但摘要要的是这一个模型
    /// 的质量。复用 `MobileSettingsStore` 里既有的 DeepSeek 凭据字段(`llmKey`/`llmModel`),
    /// 不新增一套独立的会议专属凭据。
    private func summarize(transcript: String, startedAt: Date, duration: TimeInterval,
                           hasGaps: Bool) async throws -> String {
        let dictionary = settings.dictionaryWords
        let service = CleanupService(
            baseURL: settings.usesWorkerRelay ? settings.activeLLMBaseURL : URL(string: "https://api.deepseek.com/v1")!,
            apiKey: settings.usesWorkerRelay ? settings.activeLLMKey : settings.llmKey,
            model: MobileSettingsStore.officialDeepSeekModel)
        let thinking: CleanupService.ThinkingMode = settings.meetingSummaryThinking ? .enabled : .disabled
        let chunks = MeetingSummaryPromptBuilder.chunkPromptText(transcript)

        if chunks.count <= 1 {
            return try await service.cleanStream(
                raw: transcript,
                systemPrompt: MeetingSummaryPromptBuilder.buildFinalSummary(
                    dictionary: dictionary, startedAt: startedAt, duration: duration, hasGaps: hasGaps),
                thinking: thinking, forbidsNewNumbers: false, validate: false,
                userContentOverride: MeetingSummaryPromptBuilder.userContent(transcript: transcript)
            ) { _ in }
        }

        var digests: [String] = []
        for chunk in chunks {
            let digest = try await service.cleanStream(
                raw: chunk, systemPrompt: MeetingSummaryPromptBuilder.buildChunkDigest(dictionary: dictionary),
                thinking: .disabled, forbidsNewNumbers: false, validate: false,
                userContentOverride: MeetingSummaryPromptBuilder.userContent(transcript: chunk)
            ) { _ in }
            digests.append(digest)
        }
        let combined = digests.joined(separator: "\n\n")
        return try await service.cleanStream(
            raw: combined,
            systemPrompt: MeetingSummaryPromptBuilder.buildFinalSummary(
                dictionary: dictionary, startedAt: startedAt, duration: duration, hasGaps: hasGaps),
            thinking: thinking, forbidsNewNumbers: false, validate: false,
            userContentOverride: MeetingSummaryPromptBuilder.userContent(transcript: combined)
        ) { _ in }
    }
}
