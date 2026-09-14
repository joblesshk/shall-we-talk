import Foundation
import ShallWeTalkCore

/// 会议记录的处理阶段。两条转写管线的分工(2026-08-20 与用户确认):录制中只跑端侧
/// 模型出一份粗糙草稿(`.recording`/`.transcriptDraft`),准确度不重要,只为了让用户
/// 看到"正在转写";会议结束后改用火山"录音文件识别·极速版"逐段重新识别一遍
/// (`.finalizingTranscript`),这份高精度、可选说话人分离的结果**替换**掉草稿——
/// 草稿本身不再保留。摘要只在有了最终稿之后才生成。
enum MeetingProcessingState: String, Codable {
    case recording               // 进程内正在录,端侧草稿实时产出
    case transcriptDraft         // 录完,还没开始/还没完成最终转写,展示的是端侧草稿
    case finalizingTranscript    // 正在跑火山录音文件识别(权威转写来源)
    case transcribed             // 最终转写已就绪(草稿已丢弃),等待/无需摘要
    case summarizing
    case summarized
    /// 崩溃/被杀后由 crash-recovery 补齐,等用户确认/补生成最终转写与摘要。
    case needsFinalize
    case failed
}

/// 一场会议记录。segments 是"两段合成一段"的落地形态——见 `ShallWeTalkCore.MeetingTranscript`
/// 把它们拼接为连续转写的纯函数。
struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String                  // LLM 生成;生成前 = "会议 · MM月dd日 HH:mm"
    var titleIsUserEdited: Bool         // 重新生成摘要不得覆盖用户手改过的标题
    let createdAt: Date
    var startedAt: Date
    var endedAt: Date?
    var segments: [MeetingSegment]
    /// true = 至少有一个 segment 的转写来自火山录音文件识别(权威来源);
    /// false = 仍是录制时的端侧草稿。UI 据此判断是否已经是"可信"的转写。
    var isFinalTranscript: Bool
    var summary: MeetingSummary?
    var summaryRaw: String?            // LLM 原始输出,解析失败时的兜底展示
    /// 用户手动编辑后的完整转写文本。非 nil 时,展示与"重新生成摘要"都优先用它,
    /// 而不是 segments 拼接出的结构化转写——编辑一旦发生就以用户改过的文字为准。
    var editedTranscriptText: String?
    var speakerNames: [String: String] // 用户为 speakerID 起的名字(可选)
    var state: MeetingProcessingState
    var lastError: String?
    var speakerInfoEnabled: Bool       // 录这场会时 enable_speaker_info 是否开着
    /// 最近一次本机修改时间,iCloud 合并的 LWW 键(见 `CloudMeetingSync`)。
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, titleIsUserEdited: Bool = false, createdAt: Date = Date(),
        startedAt: Date, endedAt: Date? = nil, segments: [MeetingSegment] = [],
        isFinalTranscript: Bool = false, summary: MeetingSummary? = nil, summaryRaw: String? = nil,
        editedTranscriptText: String? = nil, speakerNames: [String: String] = [:],
        state: MeetingProcessingState, lastError: String? = nil, speakerInfoEnabled: Bool,
        updatedAt: Date = Date()) {
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
        self.lastError = lastError
        self.speakerInfoEnabled = speakerInfoEnabled
        self.updatedAt = updatedAt
    }

    static func placeholderTitle(startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "会议 · \(f.string(from: startedAt))"
    }
}

extension MeetingRecord: CloudMergeableMeetingRecord {}

/// MVP 用 JSON 文件持久化,与 `HistoryStore`/`TodoStore` 同一套约定;音频单独存目录,
/// **不复用** `HistoryStore` 的 `audio/`(那里按 200MB LRU 裁剪,会静默删掉会议录音)。
final class MeetingStore: ObservableObject {
    struct DeletionTombstone: Codable, Equatable {
        let createdAt: Date
        let deletedAt: Date
    }

    @Published private(set) var meetings: [MeetingRecord] = []
    private(set) var deletionTombstones: [UUID: Date] = [:]
    private var deletionCreatedAt: [UUID: Date] = [:]

    /// 本机尚可能需要补传的墓碑。`createdAt` 不能随着原记录删除而丢失，否则重启后
    /// 无法构造符合云端格式的删除记录。
    var pendingDeletionTombstones: [(id: UUID, createdAt: Date, deletedAt: Date)] {
        deletionTombstones.compactMap { id, deletedAt in
            deletionCreatedAt[id].map { (id, $0, deletedAt) }
        }
    }

    private let dir: URL
    private let file: URL
    private let deletionsFile: URL
    private var audioDir: URL { dir.appendingPathComponent("meetings/audio", isDirectory: true) }

    /// 落盘节流:appendUtterance 每句都可能触发,90 分钟会议会是几百次全量 JSON 重写。
    /// 保留最近一次修改标记,后台每 3 秒冲刷一次;段落收尾/会议结束/进入后台时强制冲刷。
    private var isDirty = false
    private var flushTimer: Timer?
    @Published private(set) var persistenceError: String?
    private var storageReadable = false
    private var pendingAudioDeletes: [UUID: [String]] = [:]

    /// 单个原子快照是提交依据；原有两个 JSON 文件保留为兼容导出。
    private struct DiskState: Codable {
        var schemaVersion = 1
        var meetings: [MeetingRecord]
        var deletions: [String: DeletionTombstone]
        var pendingAudioDeletes: [UUID: [String]]
    }
    private var stateFile: URL { dir.appendingPathComponent("meetings-state.json") }


    func audioURL(for name: String) -> URL { audioDir.appendingPathComponent(name) }

    struct AudioArchivePlan: Sendable {
        let sourceURLs: [URL]
        let destination: URL
    }

    /// 每场会议都有一个稳定的完整录音副本名。原始分段从不因合成、识别或摘要失败而被覆盖。
    func completeAudioURL(for meetingID: UUID) -> URL {
        audioURL(for: "\(meetingID.uuidString)-complete.wav")
    }

    /// 只有所有已结束分段都存在有效 PCM 时才允许声称“完整录音”。调用方在后台合成该计划；
    /// 计划生成本身不会写入或删除任何文件。
    func completeAudioArchivePlan(for meetingID: UUID) throws -> AudioArchivePlan {
        guard let record = meetings.first(where: { $0.id == meetingID }) else {
            throw NSError(domain: "MeetingAudio", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "找不到会议记录"])
        }
        guard !record.segments.isEmpty else {
            throw NSError(domain: "MeetingAudio", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "会议没有录音片段"])
        }
        let sources = try record.segments.sorted { $0.index < $1.index }.map { segment -> URL in
            guard let name = segment.audioFileName else {
                throw NSError(domain: "MeetingAudio", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "第 \(segment.index + 1) 段录音未保存"])
            }
            let url = audioURL(for: name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 44 else {
                throw NSError(domain: "MeetingAudio", code: 13,
                              userInfo: [NSLocalizedDescriptionKey: "第 \(segment.index + 1) 段没有采集到有效音频"])
            }
            return url
        }
        return AudioArchivePlan(sourceURLs: sources, destination: completeAudioURL(for: meetingID))
    }

    init() {
        let base = AppDataDirectory.url()
        dir = base
        file = base.appendingPathComponent("meetings.json")
        deletionsFile = base.appendingPathComponent("meetings-deletions.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        do {
            install(try readState())
            storageReadable = true
        } catch {
            persistenceError = "会议记录暂时无法读取，原文件已保留：\(error.localizedDescription)"
        }
        recoverFromUnresolvedState()
        startFlushTimer()
    }

    // MARK: - 生命周期(录制中的会议)

    @discardableResult
    func beginMeeting(speakerInfoEnabled: Bool) -> MeetingRecord {
        let now = Date()
        let record = MeetingRecord(title: MeetingRecord.placeholderTitle(startedAt: now),
                                   startedAt: now, state: .recording,
                                   speakerInfoEnabled: speakerInfoEnabled)
        meetings.insert(record, at: 0)
        markDirty(flushNow: true)
        return record
    }

    func appendSegment(meetingID: UUID, segment: MeetingSegment) {
        mutate(meetingID) { $0.segments.append(segment) }
        markDirty(flushNow: true)
    }

    func appendUtterance(meetingID: UUID, segmentID: UUID, _ utterance: MeetingUtterance) {
        mutate(meetingID) { record in
            guard let i = record.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            record.segments[i].utterances.append(utterance)
        }
        markDirty(flushNow: false)
    }

    func closeSegment(meetingID: UUID, segmentID: UUID, endedAt: Date,
                      audioFileName: String?, reason: MeetingSegmentEndReason, resolved: Bool) {
        mutate(meetingID) { record in
            guard let i = record.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            record.segments[i].endedAt = endedAt
            record.segments[i].audioFileName = audioFileName
            record.segments[i].endReason = reason
            record.segments[i].isResolved = resolved
        }
        markDirty(flushNow: true)
    }

    func endMeeting(id: UUID, endedAt: Date) {
        mutate(id) { record in
            record.endedAt = endedAt
            if record.state == .recording { record.state = .transcriptDraft }
        }
        markDirty(flushNow: true)
    }

    func setState(id: UUID, _ state: MeetingProcessingState, lastError: String? = nil) {
        mutate(id) { record in
            record.state = state
            // `.needsFinalize` 与 `.transcribed` 也可能有可恢复错误；不能只因它们不是
            // `.failed` 就把刚写入的原因清掉。
            record.lastError = lastError
        }
        markDirty(flushNow: true)
    }

    /// 重新生成摘要绝不覆盖用户手改过的标题——与 `HistoryStore.updateFinalText` 同一条约定。
    func setSummary(id: UUID, summary: MeetingSummary?, raw: String?) {
        mutate(id) { record in
            record.summary = summary
            record.summaryRaw = raw
            if let summary, !record.titleIsUserEdited, !summary.title.isEmpty {
                record.title = summary.title
            }
            record.state = .summarized
        }
        markDirty(flushNow: true)
    }

    func setTitle(id: UUID, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { record in
            record.title = trimmed
            record.titleIsUserEdited = true
        }
        markDirty(flushNow: true)
    }

    func setSpeakerName(id: UUID, speakerID: String, name: String) {
        mutate(id) { record in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { record.speakerNames.removeValue(forKey: speakerID) }
            else { record.speakerNames[speakerID] = trimmed }
        }
        markDirty(flushNow: true)
    }

    /// 用户手动编辑转写后保存。清空(nil/空串)等于撤销编辑,回退到 segments 拼接的原始转写。
    func setEditedTranscript(id: UUID, text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { record in
            record.editedTranscriptText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        markDirty(flushNow: true)
    }

    /// 火山录音文件识别(权威转写)成功后,用高精度结果**整段替换**该 segment 的端侧草稿
    /// utterances——草稿不与最终稿并存,这就是"删除粗糙草稿"的落地方式:没有单独的
    /// "draft" 存储,替换即丢弃。不动音频文件名/时间边界,那些是录制时的真相。
    @discardableResult
    func replaceTranscript(meetingID: UUID, segmentID: UUID, utterances: [MeetingUtterance]) -> Bool {
        guard let i = meetings.firstIndex(where: { $0.id == meetingID }),
              let j = meetings[i].segments.firstIndex(where: { $0.id == segmentID }) else { return false }
        meetings[i].segments[j].utterances = utterances
        meetings[i].isFinalTranscript = true
        meetings[i].updatedAt = Date()
        markDirty(flushNow: true)
        return true
    }


    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let record = meetings.first(where: { $0.id == id }) else { return false }
        pendingAudioDeletes[id] = record.segments.compactMap(\.audioFileName)
        let deletedAt = Date()
        deletionTombstones[id] = deletedAt
        deletionCreatedAt[id] = record.createdAt
        meetings.removeAll { $0.id == id }
        isDirty = true
        return flush()
    }

    func applyCloudMerge(records newRecords: [MeetingRecord]?, deletions: [UUID: Date]) {
        for (id, deletedAt) in deletions {
            if let existing = deletionTombstones[id], existing >= deletedAt { continue }
            deletionTombstones[id] = deletedAt
            // 远端墓碑已经存在于云端；这里只保留一个可编码的回退值，以兼容旧格式。
            deletionCreatedAt[id] = deletionCreatedAt[id] ?? deletedAt
        }
        if let newRecords {
            // 拉取期间本机可能仍在录音、写入草稿或编辑标题。不要用发起拉取时的旧快照
            // 覆盖这些较新的本地修改；逐条按 updatedAt 再合并一次。
            var byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
            for incoming in newRecords {
                if let existing = byID[incoming.id],
                   existing.updatedAt > incoming.updatedAt || [.recording, .finalizingTranscript, .summarizing].contains(existing.state) { continue }
                byID[incoming.id] = incoming
            }
            meetings = byID.values.filter { deletionTombstones[$0.id] == nil }
                .sorted { $0.startedAt > $1.startedAt }
        } else {
            meetings.removeAll { deletionTombstones[$0.id] != nil }
        }
        markDirty(flushNow: true)
    }

    // MARK: - 存储用量 / 保留策略

    func totalAudioBytes() -> UInt64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(UInt64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + UInt64(size)
        }
    }

    /// 会议原始录音只允许用户在明确的删除确认中移除。本方法保留是为了兼容旧设置值，
    /// 但不再执行自动清除；识别、摘要、同步或容量压力都不能触碰源音频。
    func pruneAudioByRetention(_ retention: MeetingAudioRetention) {
        _ = retention
    }

    func clearAllAudio() {
        for i in meetings.indices {
            for j in meetings[i].segments.indices {
                meetings[i].segments[j].audioFileName = nil
            }
        }
        try? FileManager.default.removeItem(at: audioDir)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        markDirty(flushNow: true)
    }

    // MARK: - 崩溃恢复

    /// 任何 `state == .recording` 或存在 `endedAt == nil` 段落的记录,说明上次进程在
    /// 录制中被系统回收/崩溃。补一个 `.appTerminated` 段落收尾(endedAt 按 WAV 文件大小
    /// 反推),修复该段 WAV 头,record 转入 `.needsFinalize` 等用户确认——绝不静默丢弃。
    private func recoverFromUnresolvedState() {
        var changed = false
        for i in meetings.indices {
            var touched = false
            for j in meetings[i].segments.indices where meetings[i].segments[j].endedAt == nil {
                touched = true
                let segment = meetings[i].segments[j]
                var inferredEnd = segment.startedAt
                if let name = segment.audioFileName {
                    let url = audioURL(for: name)
                    MeetingAudioWriter.repairHeader(at: url)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? UInt64, size > 44 {
                        inferredEnd = segment.startedAt.addingTimeInterval(Double(size - 44) / 32000)
                    }
                }
                meetings[i].segments[j].endedAt = inferredEnd
                meetings[i].segments[j].endReason = .appTerminated
                meetings[i].segments[j].isResolved = false
                DiagLog.log("meeting", "崩溃恢复:补齐未闭合段落 meeting=\(meetings[i].id.uuidString.prefix(8)) segment=\(j)")
            }
            if touched || meetings[i].state == .recording {
                meetings[i].endedAt = meetings[i].endedAt ?? meetings[i].segments.compactMap(\.endedAt).max()
                meetings[i].state = .needsFinalize
                meetings[i].updatedAt = Date()
                changed = true
            }
        }
        if changed { markDirty(flushNow: true) }
    }

    // MARK: - 私有

    private func mutate(_ id: UUID, _ body: (inout MeetingRecord) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        body(&meetings[i])
        meetings[i].updatedAt = Date()
    }

    private func markDirty(flushNow: Bool) {
        isDirty = true
        if flushNow { flush() }
    }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    @discardableResult
    func flush() -> Bool {
        guard isDirty || !pendingAudioDeletes.isEmpty || !storageReadable else { return persistenceError == nil }
        do {
            if !storageReadable {
                let local = meetings
                let localDeletions = deletionTombstones
                let localCreated = deletionCreatedAt
                let localAudioDeletes = pendingAudioDeletes
                install(try readState())
                var byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
                    a.updatedAt >= b.updatedAt ? a : b
                })
                for record in local where byID[record.id].map({ $0.updatedAt <= record.updatedAt }) ?? true {
                    byID[record.id] = record
                }
                for (id, date) in localDeletions where deletionTombstones[id].map({ $0 < date }) ?? true {
                    deletionTombstones[id] = date
                    deletionCreatedAt[id] = localCreated[id] ?? date
                }
                pendingAudioDeletes.merge(localAudioDeletes, uniquingKeysWith: { _, new in new })
                meetings = byID.values.filter { deletionTombstones[$0.id] == nil }
                    .sorted { $0.startedAt > $1.startedAt }
                storageReadable = true
            }
            let deletions = Dictionary(uniqueKeysWithValues: deletionTombstones.map { id, date in
                (id.uuidString, DeletionTombstone(createdAt: deletionCreatedAt[id] ?? date, deletedAt: date))
            })
            let state = DiskState(meetings: meetings, deletions: deletions, pendingAudioDeletes: pendingAudioDeletes)
            let encoder = JSONEncoder()
            let stateData = try encoder.encode(state)
            let recordsData = try encoder.encode(meetings)
            let deletionsData = try encoder.encode(deletions)
            try stateData.write(to: stateFile, options: .atomic)
            try recordsData.write(to: file, options: .atomic)
            try deletionsData.write(to: deletionsFile, options: .atomic)
            isDirty = false
            persistenceError = nil
            // 删除意图已持久化，音频清理可安全重试，包括进程重启后的重试。
            for (id, names) in pendingAudioDeletes {
                do {
                    try MeetingAudioWriter.removeMeetingAudio(meetingID: id, referencedFileNames: names, in: audioDir)
                    pendingAudioDeletes.removeValue(forKey: id)
                    isDirty = true
                } catch {
                    persistenceError = "会议已删除，音频清理将重试：\(error.localizedDescription)"
                }
            }
            return true
        } catch {
            isDirty = true
            persistenceError = "会议尚未保存，将重试：\(error.localizedDescription)"
            DiagLog.log("meeting", persistenceError!)
            return false
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code) { return nil }
            throw error
        }
    }

    private func readState() throws -> DiskState {
        let decoder = JSONDecoder()
        if let data = try readIfPresent(stateFile) {
            let state = try decoder.decode(DiskState.self, from: data)
            guard state.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            return state
        }
        let records = try readIfPresent(file).map { try decoder.decode([MeetingRecord].self, from: $0) } ?? []
        var deletions: [String: DeletionTombstone] = [:]
        if let data = try readIfPresent(deletionsFile) {
            if let current = try? decoder.decode([String: DeletionTombstone].self, from: data) {
                deletions = current
            } else {
                let legacy = try decoder.decode([String: Date].self, from: data)
                deletions = legacy.mapValues { DeletionTombstone(createdAt: $0, deletedAt: $0) }
            }
        }
        return DiskState(meetings: records, deletions: deletions, pendingAudioDeletes: [:])
    }

    private func install(_ state: DiskState) {
        deletionTombstones = Dictionary(uniqueKeysWithValues: state.deletions.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value.deletedAt) }
        })
        deletionCreatedAt = Dictionary(uniqueKeysWithValues: state.deletions.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value.createdAt) }
        })
        meetings = state.meetings.filter { deletionTombstones[$0.id] == nil }.sorted { $0.startedAt > $1.startedAt }
        pendingAudioDeletes = state.pendingAudioDeletes
    }

}

/// 为旧版持久化值保留的枚举。新会议只采用永久保留；删除必须经过用户明确确认。
enum MeetingAudioRetention: String, CaseIterable, Identifiable {
    case keepForever = "一直保留"
    var id: String { rawValue }
}
