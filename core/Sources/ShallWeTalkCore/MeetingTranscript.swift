import Foundation

/// 会议录音的一句定稿转写。字段语义与 `VolcStreamingSession.VolcUtterance` 对齐,
/// 但这里是持久化模型(独立于 ASR 客户端类型),供 MeetingStore/云同步/UI 共用。
public struct MeetingUtterance: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    /// 相对**本段**(MeetingSegment)ASR 连接建立时刻的毫秒偏移,与火山 utterances 的
    /// start_time/end_time 口径一致。跨段拼接时不可直接相加,见 `MeetingTranscript.lines`。
    public var startMs: Int
    public var endMs: Int
    /// 豆包 `enable_speaker_info` 回传的说话人标签(不透明簇 id,如 "0"/"1")。
    /// 未开启该功能,或服务端未回传时为 nil——转写仍然完整,只是不带说话人区分。
    public var speakerID: String?
    /// definite=true 才落库；服务端终稿覆盖整段转写时统一置 true。
    public var isFinal: Bool

    public init(id: UUID = UUID(), text: String, startMs: Int, endMs: Int,
               speakerID: String? = nil, isFinal: Bool = true) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.speakerID = speakerID
        self.isFinal = isFinal
    }
}

/// 一段录音为什么结束。决定拼接时是否在文稿里插入边界提示,以及该段转写是否可能不完整。
public enum MeetingSegmentEndReason: String, Codable, Sendable {
    case manualStop        // 用户点「结束会议」
    case interruption       // 来电 / Siri / 其它 App 抢麦(AVAudioSession .began)
    case routeChange        // 蓝牙/有线耳机等路由切换,主动轮转重建引擎
    case rotation            // 长会议主动分段(§3.5),UI 不显示分隔标记
    case appTerminated      // 进程被系统回收或崩溃,下次启动时补记
    case audioStall          // 引擎在跑但采样字节数停滞(黑洞录音看门狗)
    case asrFailure          // 流式识别连接不可恢复地断开
}

/// 一段连续录音:一次音频会话 + 一条 ASR 流式连接的完整生命周期。
/// 一场会议由若干个 segment 首尾相接(interruption/routeChange/rotation 的分段)组成。
public struct MeetingSegment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var index: Int
    public var startedAt: Date
    /// nil = 仍在录制中,或异常终止后尚未被 crash-recovery 补齐。
    public var endedAt: Date?
    /// meetings/audio/<meetingID>-<index>.wav;相对文件名,不含目录。
    public var audioFileName: String?
    public var utterances: [MeetingUtterance]
    public var endReason: MeetingSegmentEndReason?
    /// false = ASR 收尾未正常完成,转写可能有缺口,UI 需要标注。
    public var isResolved: Bool

    public init(id: UUID = UUID(), index: Int, startedAt: Date, endedAt: Date? = nil,
               audioFileName: String? = nil, utterances: [MeetingUtterance] = [],
               endReason: MeetingSegmentEndReason? = nil, isResolved: Bool = true) {
        self.id = id
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioFileName = audioFileName
        self.utterances = utterances
        self.endReason = endReason
        self.isResolved = isResolved
    }
}

/// 把若干个 segment 拼接为一份连续、带时间线的会议转写。纯函数,不依赖 UIKit/AVFoundation,
/// 是「中断后两段合成一段」这条产品要求的可单测核心。
public enum MeetingTranscript {
    public struct Line: Equatable, Sendable {
        public var segmentIndex: Int
        /// 相对**会议开始时刻**(meetingStartedAt)的毫秒偏移,墙钟意义上的绝对偏移——
        /// 中断期间的真实间隔会体现在这里,不是把各段时长简单相加。
        public var offsetMs: Int
        public var speakerLabel: String
        public var text: String
        /// 该行是否为一个新 segment 的第一行(用于渲染分隔标记)。
        public var isSegmentStart: Bool
    }

    /// 把 segments 拼接为展示行。段内按 startMs 升序、段间按 startedAt 升序——服务端已按
    /// 顺序下发,这里仍防御性排序,避免网络重排/解码异常打乱转写顺序。
    public static func lines(segments: [MeetingSegment], meetingStartedAt: Date) -> [Line] {
        let ordered = segments.sorted { $0.startedAt < $1.startedAt }
        var speakerOrder: [String: Int] = [:]
        var out: [Line] = []
        for segment in ordered {
            let segmentOffsetMs = Int(segment.startedAt.timeIntervalSince(meetingStartedAt) * 1000)
            let sortedUtterances = segment.utterances.sorted { $0.startMs < $1.startMs }
            for (i, u) in sortedUtterances.enumerated() {
                let label = speakerLabel(for: u.speakerID, order: &speakerOrder)
                out.append(Line(segmentIndex: segment.index,
                                offsetMs: segmentOffsetMs + u.startMs,
                                speakerLabel: label,
                                text: u.text,
                                isSegmentStart: i == 0))
            }
        }
        return out
    }

    /// 展示用纯文本:说话人 + 时间戳 + 正文,段边界按 endReason 插入提示行。
    public static func displayText(segments: [MeetingSegment], meetingStartedAt: Date) -> String {
        formatted(segments: segments, meetingStartedAt: meetingStartedAt, includeMarkers: true) { line in
            "[\(Self.timestamp(line.offsetMs))] \(line.speakerLabel)：\(line.text)"
        }
    }

    /// 喂给摘要 LLM 的形态。同样带边界标记,让模型知道此处有真实的时间缺口,
    /// 不应臆测缺失内容去"编"出连续性。
    public static func promptText(segments: [MeetingSegment], meetingStartedAt: Date) -> String {
        formatted(segments: segments, meetingStartedAt: meetingStartedAt, includeMarkers: true) { line in
            "[\(Self.timestamp(line.offsetMs))] \(line.speakerLabel)：\(line.text)"
        }
    }

    /// 段边界提示文案。`.manualStop`/`.rotation` 返回 nil——手动结束不是"边界",
    /// 主动轮转是无痕的技术性分段,都不该打断阅读体验。
    public static func boundaryMarker(for reason: MeetingSegmentEndReason, resumedAtOffsetMs: Int) -> String? {
        let at = timestamp(resumedAtOffsetMs)
        switch reason {
        case .interruption: return "— 通话打断，\(at) 恢复 —"
        case .routeChange: return "— 音频设备切换，\(at) 恢复 —"
        case .appTerminated, .audioStall, .asrFailure: return "— 录音中断，此处可能有缺失 —"
        case .manualStop, .rotation: return nil
        }
    }

    /// 全部有转写内容的总时长估计(最后一句结束偏移),用于 UI 展示"时长"。
    public static func totalSpeechDuration(_ segments: [MeetingSegment]) -> TimeInterval {
        guard let first = segments.map({ $0.startedAt }).min() else { return 0 }
        let end = segments.compactMap { $0.endedAt }.max() ?? Date()
        return end.timeIntervalSince(first)
    }

    // MARK: - 私有

    private static func speakerLabel(for speakerID: String?, order: inout [String: Int]) -> String {
        guard let speakerID else { return "未标注" }
        if let idx = order[speakerID] { return "说话人 \(idx + 1)" }
        let idx = order.count
        order[speakerID] = idx
        return "说话人 \(idx + 1)"
    }

    private static func formatted(segments: [MeetingSegment], meetingStartedAt: Date,
                                  includeMarkers: Bool,
                                  render: (Line) -> String) -> String {
        let ordered = segments.sorted { $0.startedAt < $1.startedAt }
        let allLines = lines(segments: segments, meetingStartedAt: meetingStartedAt)
        var out: [String] = []
        var lineIndex = 0
        for (segIdx, segment) in ordered.enumerated() {
            // 边界提示反映"上一段为什么结束"(它留下的缺口),不是"这一段将来会怎么结束"。
            if includeMarkers, segIdx > 0, let reason = ordered[segIdx - 1].endReason,
               let marker = boundaryMarker(
                   for: reason,
                   resumedAtOffsetMs: Int(segment.startedAt.timeIntervalSince(meetingStartedAt) * 1000)) {
                out.append(marker)
            }
            while lineIndex < allLines.count, allLines[lineIndex].segmentIndex == segment.index {
                out.append(render(allLines[lineIndex]))
                lineIndex += 1
            }
        }
        return out.joined(separator: "\n")
    }

    private static func timestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
