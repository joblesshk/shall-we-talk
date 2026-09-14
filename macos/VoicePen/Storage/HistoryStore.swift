import Foundation
import Combine
import ShallWeTalkCore

/// 四元组数据模型(工程规划 §4.1):音频 + ASR 原文 + 整理稿 + 最终稿
/// finalText 在用户于历史页修改后写入,是归因引擎(Phase 4)的输入
struct DictationRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    var rawText: String        // ASR 原文
    var cleanText: String      // LLM 整理稿
    var finalText: String?     // 用户修改后的最终稿(nil = 未修改)
    var audioFileName: String? // 音频留存(用户可关)
    /// 端到端延迟打点(可选,带默认值):旧记录 JSON 里没有这个键也能正常解码为 nil,
    /// 不影响历史数据(离线/失败/无整理的记录同样允许为 nil)。
    var metrics: LatencyMetrics? = nil
    /// 与 iOS 同步的语音修改版本栈；旧 JSON 缺失时解码为 nil。
    var revisions: [EditRevision]? = nil
    /// finalText + revisions 的跨设备原子版本。Optional 兼容旧 history.json。
    var editVersion: HistoryEditVersion? = nil
    /// rawText/cleanText(识别正文)的独立同步版本,与 editVersion 分开比较、分别合并。
    /// nil 表示自创建以来从未被重新识别过。随 rawText/cleanText 一起上云。
    var recognitionVersion: HistoryEditVersion? = nil
    /// 本机端侧兜底稿要明确标记，用户可在网络恢复后选择云端重识别。
    /// 与 iOS 一致：这是本机诊断字段，不写入跨设备历史记录。
    var recognitionSource: RecognitionSource? = nil
    var recognitionFailure: String? = nil
    /// 本次最终文本的 ASR 完成路径；用于区分单向会话结果与整段录音回退结果。
    /// 与 metrics 一样仅保留在本机历史中，旧记录缺失时按 nil 兼容。
    var asrCompletionPath: ASRCompletionPath? = nil
    /// 流式 ASR 的本机工作记录。它只描述无敏感的链路计数和回退原因，专为定位
    /// "为什么这次退回整段识别"而保留，不写入跨设备历史记录。
    var streamingDiagnostics: ASRStreamingWorkRecord? = nil
    var cleanupStatus: CleanupStatus? = nil
    var recordingDuration: TimeInterval? = nil
}

/// 单次流式识别的本地证据。它能区分：建连前失败、配置已发但没有上行音频、
/// 音频已发但服务端无回包，以及已有中间稿但迟迟没有终稿这几类问题。
struct ASRStreamingWorkRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        case completed
        case fellBack
        case unavailable
    }

    /// 火山服务端检索会话所需的关联 ID。非凭据，仅存本机诊断记录，不随历史上云。
    var requestID: String? = nil
    var connectID: String? = nil
    var outcome: Outcome
    var configurationSent: Bool
    var audioBytesSent: Int
    var audioPacketCount: Int
    var resultFrameCount: Int
    var receivedFinalResult: Bool
    var firstPartialMillis: Int?
    var fallbackReason: String?
    var parseableResultJSONFrameCount: Int? = nil
    var resultObjectFrameCount: Int? = nil
    var topLevelTextPresentFrameCount: Int? = nil
    var topLevelNonEmptyTextFrameCount: Int? = nil
    var utterancesPresentFrameCount: Int? = nil
    var utteranceTextPresentFrameCount: Int? = nil
    var definiteUtteranceTextFrameCount: Int? = nil
    var finalFrameCount: Int? = nil
    var finalFrameHadNonEmptyTopLevelText: Bool? = nil
    var onPartialInvocationCount: Int? = nil
    var firstParseableResultMillis: Int? = nil
    var firstResultObjectMillis: Int? = nil
    var firstTopLevelTextMillis: Int? = nil
    var firstTopLevelNonEmptyTextMillis: Int? = nil
    var firstUtterancesMillis: Int? = nil
    var firstUtteranceTextMillis: Int? = nil
    var firstDefiniteUtteranceTextMillis: Int? = nil
    var firstFinalFrameMillis: Int? = nil
    var jsonDecodeFailureCount: Int? = nil
    var decompressionFailureCount: Int? = nil
    var sequenceFirst: Int32? = nil
    var sequenceLast: Int32? = nil
    var sequenceMin: Int32? = nil
    var sequenceMax: Int32? = nil
    var sequenceMonotonicityBroken: Bool? = nil
    var sequenceDuplicateCount: Int? = nil
    var messageTypeBucketCounts: [Int]? = nil
    var resultFlagsBucketCounts: [Int]? = nil
    /// 新版记录才有的会话时间线；保持 optional 以兼容已经落盘的首版诊断记录。
    var timeline: ASRStreamingTimeline? = nil

    var displayName: String {
        switch outcome {
        case .completed: return "流式 ASR 已完成"
        case .fellBack: return "流式 ASR 已回退"
        case .unavailable: return "未使用流式 ASR"
        }
    }

    var detail: String {
        let audioSeconds = Double(audioBytesSent) / 32_000
        var parts = [
            configurationSent ? "配置已发" : "配置未发",
            String(format: "上行 %.1fs/%d 包", audioSeconds, audioPacketCount),
            "回包 \(resultFrameCount) 帧",
            receivedFinalResult ? "已收终稿" : "未收终稿",
        ]
        if let fallbackReason, !fallbackReason.isEmpty { parts.append("原因：\(fallbackReason)") }
        return parts.joined(separator: " · ")
    }
}

/// 所有时点均为流式会话启动后的相对毫秒数。它不含 URL、文本或任何凭据。
struct ASRStreamingTimeline: Codable, Equatable {
    var configurationSentMillis: Int?
    var firstAudioSentMillis: Int?
    var lastAudioSentMillis: Int?
    var finishRequestedMillis: Int?
    var endFrameSentMillis: Int?
    /// SAUC 结束音频帧的负序号；配合 request/connect ID 定位服务端是否收到该帧。
    var endFrameSequence: Int32? = nil
    var firstResultFrameMillis: Int?
    var firstTextMillis: Int?
    var finalResultMillis: Int?

    private static func seconds(_ millis: Int) -> String {
        String(format: "%.2fs", Double(millis) / 1000)
    }

    private static func interval(_ later: Int?, after earlier: Int?) -> String? {
        guard let later, let earlier else { return nil }
        return seconds(max(0, later - earlier))
    }

    /// 先给关键因果区间，再给绝对事件时点。读一条慢记录即可判断卡在何处。
    var detail: String {
        var parts: [String] = []
        if let setup = configurationSentMillis { parts.append("建连至配置 \(Self.seconds(setup))") }
        if let waitForFirstFrame = Self.interval(firstResultFrameMillis, after: endFrameSentMillis) {
            parts.append("结束帧至首回包 \(waitForFirstFrame)")
        }
        if let waitForFinal = Self.interval(finalResultMillis, after: endFrameSentMillis) {
            parts.append("结束帧至终稿 \(waitForFinal)")
        }
        if let uploadFlush = Self.interval(endFrameSentMillis, after: finishRequestedMillis) {
            parts.append("停止至结束帧 \(uploadFlush)")
        }
        if let endFrameSequence { parts.append("结束帧序号 \(endFrameSequence)") }
        let milestones: [(String, Int?)] = [
            ("首音频", firstAudioSentMillis), ("末音频", lastAudioSentMillis),
            ("停止", finishRequestedMillis), ("结束帧", endFrameSentMillis),
            ("首回包", firstResultFrameMillis), ("首文本", firstTextMillis),
            ("终稿", finalResultMillis),
        ]
        let timeline = milestones.compactMap { label, value in
            value.map { "\(label)@\(Self.seconds($0))" }
        }.joined(separator: " · ")
        if !timeline.isEmpty { parts.append(timeline) }
        return parts.joined(separator: " · ")
    }
}

enum RecognitionSource: String, Codable {
    case cloud
    case onDevice
}

enum ASRCompletionPath: String, Codable {
    case unidirectional
    case wholeRecording
    case onDevice

    var displayName: String {
        switch self {
        case .unidirectional: return "单向 ASR"
        case .wholeRecording: return "整体录音 ASR"
        case .onDevice: return "端侧 ASR 兜底"
        }
    }

    var systemImage: String {
        switch self {
        case .unidirectional: return "waveform"
        case .wholeRecording: return "arrow.triangle.2.circlepath"
        case .onDevice: return "wifi.slash"
        }
    }
}

/// 满足 ShallWeTalkCore.DictionaryMiner 的最小字段要求,使其不必依赖本存储层。
extension DictationRecord: DictionaryMinableRecord {}
/// 满足 ShallWeTalkCore.ASRContextBuilder 的最小字段要求(同上,加一个 date)。
extension DictationRecord: RecentTextRecord {}

/// MVP 用 JSON 文件持久化;数据量上来后迁 SwiftData,模型不变
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []
    /// 删除墓碑单独持久化，防止下一次云端并集合并把已删记录重新导入。
    private(set) var deletionTombstones: [UUID: Date] = [:]

    private let dir: URL
    private let persistence: HistoryPersistence<DictationRecord>
    @Published private(set) var persistenceError: String?
    @Published private(set) var hasUnsavedChanges = false
    private var loadBlocked = false
    /// 读取受阻期间缓冲的原始云记录,尚未与任何本地状态合并;恢复后在
    /// `retryPersistence()` 里以恢复的磁盘状态为基础重放(见 `applyCloudMerge(cloudRecords:)`)。
    private var pendingCloudRecords: [CloudHistoryRecord] = []
    private var pendingAudioDeletions: Set<String> = []
    private static let editOriginID: String = {
        let key = "historyEditOriginID.v1"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    init(directory: URL? = nil, persistence: HistoryPersistence<DictationRecord>? = nil) {
        let base = directory ?? AppDataDirectory.url()
        dir = base
        self.persistence = persistence ?? HistoryPersistence(directory: base)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("audio"),
                                                 withIntermediateDirectories: true)
        load()
        if !loadBlocked, FileManager.default.fileExists(atPath: base.appendingPathComponent("history-transaction.json").path) {
            retryPersistence()
        }
    }

    func append(_ r: DictationRecord) {
        // iOS 的短时“撤销删除”会用同一 UUID 重新 append；在墓碑尚未上云前允许恢复。
        deletionTombstones.removeValue(forKey: r.id)
        records.removeAll { $0.id == r.id }
        records.insert(r, at: 0)
        save()
    }

    /// 某条记录的音频文件 URL(供批量基准重放);无音频返回 nil
    func audioURL(for record: DictationRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        return dir.appendingPathComponent("audio").appendingPathComponent(name)
    }

    /// 有留存音频的历史记录(批量基准的可选测试素材)
    var clipsWithAudio: [DictationRecord] { records.filter { $0.audioFileName != nil } }

    /// 用户在历史页编辑最终稿 → 记录修改(未来归因引擎的信号源)
    /// 只重做整理，不重写识别来源，也不覆盖请求期间发生的手动编辑。
    @discardableResult
    func replaceCleanup(expected: DictationRecord, cleanText: String) -> Bool {
        guard let i = records.firstIndex(where: { $0.id == expected.id }),
              records[i].rawText == expected.rawText,
              records[i].cleanText == expected.cleanText,
              records[i].finalText == expected.finalText,
              records[i].recognitionVersion == expected.recognitionVersion,
              records[i].editVersion == expected.editVersion else { return false }
        records[i].cleanText = cleanText
        records[i].cleanupStatus = .succeeded
        records[i].recognitionVersion = .next(after: records[i].recognitionVersion, originID: Self.editOriginID)
        save()
        return true
    }

    func updateFinalText(id: UUID, finalText: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].finalText = (finalText == records[i].cleanText) ? nil : finalText
        records[i].editVersion = .next(after: records[i].editVersion,
                                             originID: Self.editOriginID)
        save()
    }

    /// 用云端重新识别时只替换 ASR/整理稿；用户已编辑的最终稿必须保留。
    /// 推进 recognitionVersion(与 finalText/revisions 的 editVersion 相互独立),
    /// 否则云端写保护会用"整条记录版本号未变"拒绝这次正文更新(2026-09-06 回归审查 #2)。
    func replaceRecognition(id: UUID, rawText: String, cleanText: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].rawText = rawText
        records[i].cleanText = cleanText
        records[i].cleanupStatus = nil
        records[i].recognitionSource = .cloud
        records[i].recognitionFailure = nil
        records[i].asrCompletionPath = .wholeRecording
        records[i].recognitionVersion = .next(after: records[i].recognitionVersion,
                                              originID: Self.editOriginID)
        save()
    }

    @discardableResult
    func pushRevisionIfUnchanged(id: UUID, instructionRaw: String, before: String, after: String) -> Bool {
        guard let record = records.first(where: { $0.id == id }),
              (record.finalText ?? record.cleanText) == before else { return false }
        pushRevision(id: id, instructionRaw: instructionRaw, before: before, after: after)
        return true
    }

    func pushRevision(id: UUID, instructionRaw: String, before: String, after: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].revisions = (records[i].revisions ?? []) + [
            EditRevision(instructionRaw: instructionRaw, before: before, after: after)
        ]
        records[i].finalText = after
        records[i].editVersion = .next(after: records[i].editVersion,
                                             originID: Self.editOriginID)
        save()
    }

    @discardableResult
    func undoLastRevision(id: UUID) -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }),
              var revisions = records[i].revisions, let revision = revisions.last,
              (records[i].finalText ?? records[i].cleanText) == revision.after else { return false }
        revisions.removeLast()
        records[i].revisions = revisions.isEmpty ? nil : revisions
        records[i].finalText = revision.before == records[i].cleanText ? nil : revision.before
        records[i].editVersion = .next(after: records[i].editVersion, originID: Self.editOriginID)
        save()
        return true
    }

    /// iCloud 合并结果整体替换(保留本地音频关联:按 id 回填 audioFileName)
    func replaceAll(_ newRecords: [DictationRecord]) {
        let localByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let audioByID = Dictionary(records.compactMap { r in r.audioFileName.map { (r.id, $0) } },
                                   uniquingKeysWith: { a, _ in a })
        records = newRecords.filter { deletionTombstones[$0.id] == nil }.map { r in
            var r = r
            if r.audioFileName == nil { r.audioFileName = audioByID[r.id] }
            // 云端历史故意不写本机诊断，但同步不能把已记录的耗时/识别路径抹掉。
            if let local = localByID[r.id] {
                if r.metrics == nil { r.metrics = local.metrics }
                if r.recognitionSource == nil { r.recognitionSource = local.recognitionSource }
                if r.rawText.isEmpty { r.recognitionFailure = local.recognitionFailure }
                if r.asrCompletionPath == nil { r.asrCompletionPath = local.asrCompletionPath }
                if r.streamingDiagnostics == nil { r.streamingDiagnostics = local.streamingDiagnostics }
            }
            return r
        }
        save()
    }

    func delete(id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        deletionTombstones[id] = Date()
        scheduleAudioDeletion(for: records[i])
        records.remove(at: i)
        save()
    }

    /// 应用云端合并结果与墓碑。即使本轮没有新增文本，也必须持久化远端删除。
    func applyCloudMerge(records newRecords: [DictationRecord]?, deletions: [UUID: Date]) {
        for (id, deletedAt) in deletions {
            if let existing = deletionTombstones[id], existing >= deletedAt { continue }
            deletionTombstones[id] = deletedAt
        }
        let source = newRecords ?? records
        let removed = records.filter { deletionTombstones[$0.id] != nil }
        for record in removed { scheduleAudioDeletion(for: record) }
        replaceAll(source)

    }

    /// 云端 I/O 返回后用最新本地状态再次合并，保护等待期间的新增、编辑、重识别和删除。
    ///
    /// 启动读取受阻(`loadBlocked`)期间不应用，只缓冲原始云记录:这时内存里的 records
    /// 并不是磁盘真实状态(读取失败,可能缺失版本更新的本地记录),把云端数据合并进这份
    /// 不完整快照会让旧云记录以"本地没有"的名义被当成新记录插入；等磁盘恢复可读后，
    /// `retryPersistence()` 会以恢复的磁盘状态为基础重放这份缓冲(2026-09-06 回归审查 #1)。
    @discardableResult
    func applyCloudMerge(cloudRecords: [CloudHistoryRecord])
        -> (inserted: Int, adoptedFinal: Int, removed: Int, deferred: Bool) {
        guard !loadBlocked else {
            pendingCloudRecords.append(contentsOf: cloudRecords)
            return (0, 0, 0, true)
        }
        let outcome = applyCloudMergeNow(cloudRecords: cloudRecords)
        return (outcome.inserted, outcome.adoptedFinal, outcome.removed, false)
    }

    @discardableResult
    private func applyCloudMergeNow(cloudRecords: [CloudHistoryRecord])
        -> (inserted: Int, adoptedFinal: Int, removed: Int) {
        let outcome = CloudHistoryMerge.merge(
            local: records, localDeletions: deletionTombstones, cloud: cloudRecords
        ) { rec in
            DictationRecord(id: rec.id, date: rec.date, rawText: rec.rawText,
                            cleanText: rec.cleanText, finalText: rec.finalText,
                            audioFileName: nil, revisions: rec.revisions,
                            editVersion: rec.editVersion, recognitionVersion: rec.recognitionVersion)
        }
        if outcome.records != nil || outcome.deletionsChanged || hasUnsavedChanges {
            applyCloudMerge(records: outcome.records, deletions: outcome.deletions)
        }
        return (outcome.inserted, outcome.adoptedFinal, outcome.removed)
    }

    func saveAudio(_ wav: Data) -> String? {
        let name = "\(UUID().uuidString).wav"
        let url = dir.appendingPathComponent("audio").appendingPathComponent(name)
        do { try wav.write(to: url); return name } catch { return nil }
    }

    /// Audio may be large; never hold the UI executor while writing it.
    /// Capture only values, not this observable store, across the task boundary.
    func saveAudioAsync(_ wav: Data) async -> String? {
        let name = "\(UUID().uuidString).wav"
        let url = dir.appendingPathComponent("audio").appendingPathComponent(name)
        return await Task.detached(priority: .utility) {
            do {
                try wav.write(to: url, options: .atomic)
                return name
            } catch {
                return nil
            }
        }.value
    }

    func clearAll() {
        let now = Date()
        for record in records {
            deletionTombstones[record.id] = now
            scheduleAudioDeletion(for: record)
        }
        records.removeAll()
        save()
    }

    private func load() {
        do {
            let state = try persistence.load()
            loadBlocked = false
            deletionTombstones = Dictionary(state.deletions.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }, uniquingKeysWith: { max($0, $1) })
            records = Array(Dictionary(state.records.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first }).values)
                .filter { deletionTombstones[$0.id] == nil }
                .sorted { $0.date > $1.date }
        } catch {
            loadBlocked = true
            persistenceError = "历史记录暂时无法读取，已暂停覆盖原文件。请恢复文件后重试。"
        }
    }

    private func save() {
        hasUnsavedChanges = true
        _ = retryPersistence()
    }

    /// Retry uses the in-memory state; a failed save never pretends to be durable.
    /// If startup could not read existing files, preserve them until a read succeeds.
    ///
    /// 读取受阻期间,内存里的 `records` 只可能是本地新增/编辑的临时状态(云端合并已被
    /// `applyCloudMerge(cloudRecords:)` 缓冲,不会混进来),因此恢复时可以安全地整条采用
    /// ——它们在磁盘和云端此刻都没有对应版本可比较。恢复顺序:先用刚读回的磁盘状态
    /// 重放缓冲的云端合并(按既有版本规则,不会覆盖磁盘上更新的本地编辑/音频关联)，
    /// 再叠加这些纯本地的新增/编辑(2026-09-06 回归审查 #1)。
    @discardableResult
    func retryPersistence() -> Bool {
        if loadBlocked {
            let pendingLocal = records
            let pendingLocalDeletions = deletionTombstones
            load()
            guard !loadBlocked else { return false }
            if !pendingCloudRecords.isEmpty {
                _ = applyCloudMergeNow(cloudRecords: pendingCloudRecords)
                pendingCloudRecords.removeAll()
            }
            deletionTombstones.merge(pendingLocalDeletions, uniquingKeysWith: { max($0, $1) })
            var merged = Dictionary(records.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
            for record in pendingLocal { merged[record.id] = record }
            records = merged.values.filter { deletionTombstones[$0.id] == nil }
                .sorted { $0.date > $1.date }
        }
        do {
            try persistence.save(.init(
                records: records,
                deletions: Dictionary(uniqueKeysWithValues: deletionTombstones.map { ($0.key.uuidString, $0.value) })))
            hasUnsavedChanges = false
            persistenceError = nil
            removeCommittedAudio()
            return true
        } catch {
            hasUnsavedChanges = true
            persistenceError = "历史记录尚未保存到本机，请保持应用打开并重试。"
            return false
        }
    }

    private func scheduleAudioDeletion(for record: DictationRecord) {
        if let name = record.audioFileName { pendingAudioDeletions.insert(name) }
        for revision in record.revisions ?? [] {
            if let name = revision.audioFileName { pendingAudioDeletions.insert(name) }
        }
    }

    private func removeCommittedAudio() {
        guard !pendingAudioDeletions.isEmpty else { return }
        let referenced = Set(records.flatMap { record in
            [record.audioFileName].compactMap { $0 }
                + (record.revisions ?? []).compactMap { $0.audioFileName }
        })
        for name in pendingAudioDeletions {
            if !referenced.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("audio").appendingPathComponent(name))
            }
        }
        pendingAudioDeletions.removeAll()
    }
}
