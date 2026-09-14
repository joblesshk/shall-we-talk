import Foundation
import ShallWeTalkCore

/// 会议录制过程中的端侧草稿转写。定位与准确度要求(2026-08-20 与用户确认):
/// 不追求精度,只为了让用户在录音过程中看到"正在转写"的实时反馈;会议结束后
/// 由 `VolcFileTranscription`(火山录音文件识别)整段重新识别、**替换**掉这里产出的草稿,
/// 草稿本身不长期保留。
///
/// 实现选择:不用新 Speech 框架的低层流式输入 API,而是复用已经在这个仓库里跑通的
/// `OnDeviceTranscriber.transcribe(wav:)`(整段/批量,见其文档——原本是云端识别失败时的
/// 离线兜底)——每攒够一小段音频窗口就整段转写一次,足够满足"低精度、周期性提示"的
/// 要求,不需要再引入一条尚未验证过的实时流式端侧识别路径。
final class MeetingLiveCaptioner {
    private let lock = NSLock()
    private var buffer = Data()
    private var windowStartMs = 0
    private var isTranscribing = false
    private var generation = 0
    private var segmentID: UUID?
    /// 攒够这么多秒音频就出一次草稿。不用更短:端侧整段识别本身有秒级开销,
    /// 窗口太短会导致转写任务排队追不上录音速度。
    private let windowSeconds: Double = 12
    private let bytesPerSecond: Double = 32_000 // 16kHz mono Int16

    /// 每定稿一段草稿回调一次。回调线程不固定(Task 内部),调用方自行决定要不要跳回主线程。
    var onDraftUtterance: ((UUID, MeetingUtterance) -> Void)?

    func reset(segmentID: UUID? = nil) {
        lock.lock()
        generation &+= 1
        self.segmentID = segmentID
        buffer.removeAll()
        windowStartMs = 0
        isTranscribing = false
        lock.unlock()
    }

    /// 供 `Recorder.onChunk` 直接挂载,音频线程调用,非阻塞(攒到窗口才派发一次转写任务)。
    func feed(_ pcm: Data) {
        lock.lock()
        buffer.append(pcm)
        var windowPCM: Data?
        var startMs = 0
        var taskGeneration = 0
        var taskSegmentID: UUID?
        if !isTranscribing, Double(buffer.count) / bytesPerSecond >= windowSeconds {
            windowPCM = buffer
            startMs = windowStartMs
            buffer.removeAll()
            windowStartMs += Int(Double(windowPCM!.count) / bytesPerSecond * 1000)
            isTranscribing = true
            taskGeneration = generation
            taskSegmentID = segmentID
        }
        lock.unlock()
        guard let windowPCM, let taskSegmentID else { return }
        runTranscription(windowPCM, startMs: startMs, generation: taskGeneration, segmentID: taskSegmentID)
    }

    /// 段落结束时也提交不足 12 秒的尾音，避免实时草稿少掉最后一句。
    func flush() {
        lock.lock()
        guard !isTranscribing, !buffer.isEmpty else { lock.unlock(); return }
        let windowPCM = buffer
        let startMs = windowStartMs
        let taskGeneration = generation
        guard let taskSegmentID = segmentID else { lock.unlock(); return }
        buffer.removeAll()
        windowStartMs += Int(Double(windowPCM.count) / bytesPerSecond * 1000)
        isTranscribing = true
        lock.unlock()
        runTranscription(windowPCM, startMs: startMs, generation: taskGeneration, segmentID: taskSegmentID)
    }

    /// 锁的获取/释放必须留在同步函数边界内——Swift 6 禁止在 async 函数体中直接调用
    /// lock/unlock(可能跨 suspension point 被错误持有),与 `VolcStreamingSession.withLockedState`
    /// 同一约束、同一解法。
    private func clearTranscribingFlag(for generation: Int) {
        lock.lock()
        if self.generation == generation { isTranscribing = false }
        lock.unlock()
    }

    private func runTranscription(_ pcm: Data, startMs: Int, generation: Int, segmentID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            defer { self.clearTranscribingFlag(for: generation) }
            guard #available(iOS 26.0, *), OnDeviceTranscriber.isSupported,
                  await OnDeviceTranscriber.isReady else { return }
            let wav = Recorder.wav(pcm: pcm, sampleRate: 16000, channels: 1)
            guard let text = try? await OnDeviceTranscriber().transcribe(wav: wav) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard self.isCurrent(generation) else { return }
            let endMs = startMs + Int(Double(pcm.count) / self.bytesPerSecond * 1000)
            self.onDraftUtterance?(segmentID, MeetingUtterance(text: trimmed, startMs: startMs, endMs: endMs,
                                                                speakerID: nil, isFinal: false))
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation
    }
}
