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
    /// 有原音但 ASR/后处理未能产出文字时的本机错误。
    /// nil 表示正常记录；旧 JSON 没有该字段时会按 nil 解码。
    var recognitionError: String? = nil
    /// 端到端延迟打点(可选,带默认值):旧记录 JSON 里没有这个键也能正常解码为 nil,
    /// 不影响历史数据(离线/失败/无整理的记录同样允许为 nil)。
    var metrics: LatencyMetrics? = nil
    /// 这条记录的 ASR 原文由哪个引擎产出。与 metrics 同样是可选带默认值,旧记录解码为 nil。
    /// 本机字段,不上云:同一条记录在不同设备上的识别来源本就可能不同。
    var recognitionSource: RecognitionSource? = nil
    /// 端侧转写稿,用于在历史页标出「两个引擎没谈拢」的位置(见 UncertainSpans)。
    /// 端侧不可用时为 nil。本机字段,不上云。
    var onDeviceText: String? = nil
    /// 语音修改的版本栈(语音二次修改-执行方略.md v2 §2)。nil = 从未语音修改过;
    /// 撤销 = 弹栈回写 finalText。随 finalText 一起上云(见 CloudHistorySync)。
    var revisions: [EditRevision]? = nil
    /// finalText + revisions 的跨设备原子版本。Optional 兼容旧 history.json。
    var editVersion: HistoryEditVersion? = nil
    /// rawText/cleanText(识别正文)的独立同步版本,与 editVersion 分开比较、分别合并。
    /// nil 表示自创建以来从未被重新识别过。随 rawText/cleanText 一起上云。
    var recognitionVersion: HistoryEditVersion? = nil
    /// 流式 ASR 的本机开发者诊断时间线；不含 URL、文本或凭据，且不写入跨设备历史记录。
    /// 仅供开发诊断读取，历史界面不得渲染；用于和 macOS 同口径定位建连、上行、
    /// 首回包与终稿收尾的耗时。
    var streamingDiagnostics: ASRStreamingWorkRecord? = nil
    var cleanupStatus: CleanupStatus? = nil
    var recordingDuration: TimeInterval? = nil
}

/// ASR 原文的产出引擎。
///
/// 端侧只在云端流式与整段重试**都失败**时兜底(见 DictationController.finish),
/// 质量低于云端(2026-08-14 实测端侧相对云端字符差异率约 11.9%),因此需要标记出来,
/// 让用户在历史页看到并可一键用云端重识别。
enum RecognitionSource: String, Codable {
    case cloud
    case onDevice
}

/// 单次流式识别的本地证据。旧记录没有该字段时保持 nil，不影响历史解码。
struct ASRStreamingWorkRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        case completed
        case fellBack
        case unavailable
    }

    /// 服务端会话关联 ID。非凭据，仅存本机诊断记录，供与 Mac 记录同口径追查。
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

/// 以流式会话启动为零点的相对时间线，与 Mac 的工作记录口径一致。
struct ASRStreamingTimeline: Codable, Equatable {
    var configurationSentMillis: Int?
    var firstAudioSentMillis: Int?
    var lastAudioSentMillis: Int?
    var finishRequestedMillis: Int?
    var endFrameSentMillis: Int?
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
    /// 音频留档总量上限:只留最近约 200MB,写入时按修改时间从旧到新裁剪。
    /// 语音 AAC 单声道 16k 每分钟约 200KB,200MB 够存约 16 小时口述,老的自动淘汰。
    static let maxAudioBytes: UInt64 = 200 * 1024 * 1024
    private static let editOriginID: String = {
        let key = "historyEditOriginID.v1"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    private var audioDir: URL { dir.appendingPathComponent("audio", isDirectory: true) }
    /// 供播放/存在性判断:按文件名解析音频绝对路径。
    func audioURL(for name: String) -> URL { audioDir.appendingPathComponent(name) }

    func audioURL(forRecordID id: UUID) -> URL? {
        guard let name = records.first(where: { $0.id == id })?.audioFileName else { return nil }
        let url = audioURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

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
        // 备忘页的短时“撤销删除”会用同一 UUID 重新 append；墓碑尚未上云前允许恢复。
        deletionTombstones.removeValue(forKey: r.id)
        records.removeAll { $0.id == r.id }
        records.insert(r, at: 0)
        save()
    }

    /// 离线兜底记录被用户要求用云端重识别后,整条替换识别与整理结果。
    /// 不动 finalText:用户若已手改过,重识别不该覆盖他的编辑。
    /// 推进 recognitionVersion(与 finalText/revisions 的 editVersion 相互独立),
    /// 否则云端写保护会用"整条记录版本号未变"拒绝这次正文更新(2026-09-06 回归审查 #2)。
    func replaceRecognition(id: UUID, rawText: String, cleanText: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].rawText = rawText
        records[i].cleanText = cleanText
        records[i].cleanupStatus = nil
        records[i].recognitionSource = .cloud
        records[i].recognitionError = nil
        records[i].recognitionVersion = .next(after: records[i].recognitionVersion,
                                              originID: Self.editOriginID)
        save()
    }

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

    /// 语音修改(修改模式)成功应用后落库一条版本记录,`finalText` 指向最新稿。
    func pushRevision(id: UUID, instructionRaw: String, before: String, after: String,
                      audioFileName: String? = nil) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let revision = EditRevision(instructionRaw: instructionRaw, before: before,
                                    after: after, audioFileName: audioFileName)
        records[i].revisions = (records[i].revisions ?? []) + [revision]
        records[i].finalText = after
        records[i].editVersion = .next(after: records[i].editVersion,
                                             originID: Self.editOriginID)
        save()
    }

    /// 撤销到这次修改的 before；若用户随后又编辑过正文，不覆盖更晚的内容。
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
            // 云端历史刻意不包含本机诊断；合并不能让本机耗时/路径消失。
            if let local = localByID[r.id] {
                if r.metrics == nil { r.metrics = local.metrics }
                if r.recognitionSource == nil { r.recognitionSource = local.recognitionSource }
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

    /// 后台读取云端期间本地仍可能新增、编辑、重识别或删除。提交时必须以此刻的 records
    /// 与墓碑重新合并远端原始记录，不能应用后台基于旧快照生成的完整数组。
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
        applyCloudMerge(records: outcome.records, deletions: outcome.deletions)
        return (outcome.inserted, outcome.adoptedFinal, outcome.removed)
    }

    /// 录音完成后直接把已完整封装的 WAV 后台存盘,成功回主线程回传文件名。
    /// 不再使用 AVAssetExportSession: iOS 上的高容量音频转码 XPC 可能长时间不回调,
    /// 导致待办一直“原音处理中”,严重时连 App 启动/交互也被拖死。
    func archiveAudio(_ wav: Data, id: UUID, completion: @escaping (String?) -> Void) {
        let name = "\(id.uuidString).wav"
        let dst = audioURL(for: name)
        let audioDir = self.audioDir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            do {
                try wav.write(to: dst, options: .atomic)
                Self.pruneAudio(in: audioDir)
                DiagLog.log("audioArchive", "归档成功 id=\(id.uuidString.suffix(8)) file=\(name) bytes=\(wav.count)")
                DispatchQueue.main.async { completion(name) }
            } catch {
                try? FileManager.default.removeItem(at: dst)
                DiagLog.log("audioArchive", "归档失败 id=\(id.uuidString.suffix(8)) error=\(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// 异步版归档接口：调用方可以在 ASR 前启动写入，再与网络识别并行。
    /// 识别成功/失败出口在建档前 await 该结果，保证 WAV 关联不会因抛错丢失。
    func archiveAudio(_ wav: Data, id: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            archiveAudio(wav, id: id) { name in
                continuation.resume(returning: name)
            }
        }
    }

    /// 音频转码成功后回填记录的文件名(触发 UI:出现播放按钮)。
    func setAudioFileName(id: UUID, name: String?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].audioFileName = name
        save()
    }

    /// 删除未被任何历史记录引用的临时归档。仅用于“语音修改”已成功
    /// 识别、但并未产生新版本的情形，避免留下没有记录可播放的孤儿文件。
    func removeUnreferencedAudio(named name: String?) {
        guard let name,
              !records.contains(where: { $0.audioFileName == name }),
              !records.contains(where: { record in
                  (record.revisions ?? []).contains(where: { $0.audioFileName == name })
              }) else { return }
        try? FileManager.default.removeItem(at: audioURL(for: name))
    }

    /// 容量裁剪:按修改时间从新到旧累计,超过上限的旧文件删除。后台队列调用。
    private static func pruneAudio(in audioDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sorted = files.compactMap { url -> (URL, Date, UInt64)? in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = v.contentModificationDate else { return nil }
            return (url, date, UInt64(v.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }   // 新 → 旧
        var running: UInt64 = 0
        for (url, _, size) in sorted {
            running += size
            if running > maxAudioBytes { try? fm.removeItem(at: url) }
        }
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
