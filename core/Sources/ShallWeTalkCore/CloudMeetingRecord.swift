import Foundation

/// 跨端会议同步的云端记录:iCloud 容器 `Documents/Meetings/<UUID>.json` 的文件格式。
/// 仅文本(标题/摘要/逐字稿),音频永不上云——与 `CloudHistoryRecord` 对历史记录的规则一致。
///
/// 与 `CloudHistoryRecord` 的字段级合并(优先保留本地未编辑字段)不同,会议记录通常只由
/// 正在录制的那台设备持续写入,其它设备只是接收方,因此采用更简单的整条记录 LWW
/// (last-write-wins,按 `updatedAt` 比较)语义,由 `updatedAt` 字段承载。
public struct CloudMeetingRecord: Codable, Equatable, Sendable {
    public struct Utterance: Codable, Equatable, Sendable {
        public var text: String
        public var startMs: Int
        public var endMs: Int
        public var speakerID: String?

        public init(text: String, startMs: Int, endMs: Int, speakerID: String? = nil) {
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
            self.speakerID = speakerID
        }
    }

    /// 云端段落——刻意不带 `audioFileName`:音频是本机字段,不参与同步。
    public struct Segment: Codable, Equatable, Sendable {
        public var index: Int
        public var startedAt: Date
        public var endedAt: Date?
        public var endReason: String?
        public var utterances: [Utterance]
        public var isResolved: Bool

        public init(index: Int, startedAt: Date, endedAt: Date? = nil, endReason: String? = nil,
                   utterances: [Utterance] = [], isResolved: Bool = true) {
            self.index = index
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.endReason = endReason
            self.utterances = utterances
            self.isResolved = isResolved
        }
    }

    public let id: UUID
    public var title: String
    public var titleIsUserEdited: Bool
    public let createdAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var segments: [Segment]
    /// true = 该会议至少一段已经是火山录音文件识别的权威转写(端侧草稿已被替换/丢弃)。
    public var isFinalTranscript: Bool
    public var summary: MeetingSummary?
    public var summaryRaw: String?
    /// 用户手动编辑后的完整转写;非 nil 时其它设备应优先展示这份文字。
    public var editedTranscriptText: String?
    public var speakerNames: [String: String]
    /// `MeetingProcessingState.rawValue`(iOS 端定义,这里存原始字符串避免 core↔App 循环依赖)。
    public var state: String
    public var speakerInfoEnabled: Bool
    /// 本条记录最近一次本机修改的时间,LWW 合并键。
    public var updatedAt: Date
    /// 删除墓碑时间。非 nil 时其余字段应为空,避免删除后仍在云端保留内容。
    public var deletedAt: Date?

    public init(id: UUID, title: String, titleIsUserEdited: Bool = false, createdAt: Date,
               startedAt: Date, endedAt: Date? = nil, segments: [Segment] = [],
               isFinalTranscript: Bool = false, summary: MeetingSummary? = nil, summaryRaw: String? = nil,
               editedTranscriptText: String? = nil, speakerNames: [String: String] = [:],
               state: String, speakerInfoEnabled: Bool, updatedAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.titleIsUserEdited = titleIsUserEdited
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.isFinalTranscript = isFinalTranscript
        self.summary = summary
        self.summaryRaw = summaryRaw
        self.editedTranscriptText = editedTranscriptText
        self.speakerNames = speakerNames
        self.state = state
        self.speakerInfoEnabled = speakerInfoEnabled
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public static func tombstone(id: UUID, createdAt: Date, deletedAt: Date) -> CloudMeetingRecord {
        CloudMeetingRecord(id: id, title: "", createdAt: createdAt, startedAt: createdAt,
                           state: "", speakerInfoEnabled: false, updatedAt: deletedAt, deletedAt: deletedAt)
    }

    public static func decode(_ data: Data) throws -> CloudMeetingRecord {
        try JSONDecoder().decode(CloudMeetingRecord.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public var fileName: String { "\(id.uuidString).json" }
}

/// 各端本地会议记录参与云端合并所需的最小字段。
public protocol CloudMergeableMeetingRecord {
    var id: UUID { get }
    var updatedAt: Date { get }
}

/// 会议同步的合并语义:按 id 取并集;每条记录整体 LWW(updatedAt 更新者赢),
/// 墓碑优先于任何内容。比 `CloudHistoryMerge` 的字段级合并简单,原因见类型文档。
public enum CloudMeetingMerge {
    public struct Outcome<R> {
        public let records: [R]?
        public let inserted: Int
        public let updated: Int
        public let deletions: [UUID: Date]
        public let removed: Int
        public let deletionsChanged: Bool
    }

    public static func merge<R: CloudMergeableMeetingRecord>(
        local: [R],
        localDeletions: [UUID: Date] = [:],
        cloud: [CloudMeetingRecord],
        makeRecord: (CloudMeetingRecord) -> R
    ) -> Outcome<R> {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var deletions = localDeletions
        var inserted = 0
        var updated = 0

        for rec in cloud {
            guard let deletedAt = rec.deletedAt else { continue }
            if let existing = deletions[rec.id], existing >= deletedAt { continue }
            deletions[rec.id] = deletedAt
        }
        let deletionsChanged = deletions != localDeletions
        let localIDs = Set(byID.keys)
        byID = byID.filter { deletions[$0.key] == nil }
        let removed = localIDs.subtracting(byID.keys).count

        for rec in cloud {
            guard rec.deletedAt == nil, deletions[rec.id] == nil else { continue }
            if let existing = byID[rec.id] {
                if rec.updatedAt > existing.updatedAt {
                    byID[rec.id] = makeRecord(rec)
                    updated += 1
                }
            } else {
                byID[rec.id] = makeRecord(rec)
                inserted += 1
            }
        }
        guard inserted > 0 || updated > 0 || removed > 0 else {
            return Outcome(records: nil, inserted: 0, updated: 0,
                           deletions: deletions, removed: 0, deletionsChanged: deletionsChanged)
        }
        return Outcome(records: Array(byID.values), inserted: inserted, updated: updated,
                       deletions: deletions, removed: removed, deletionsChanged: deletionsChanged)
    }
}
