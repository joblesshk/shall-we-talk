import Foundation
import ShallWeTalkCore

/// `MeetingRecord` ⇄ `CloudMeetingRecord` 的转换。云端记录**永不带音频**——
/// `audioFileName` 转出去时丢弃,转回来时恒为 nil,与 `CloudHistorySync` 对
/// 历史记录音频的规则一致(见该文件"仅文本,音频不上云"的注释)。
extension MeetingRecord {
    func cloudRecord() -> CloudMeetingRecord {
        CloudMeetingRecord(
            id: id, title: title, titleIsUserEdited: titleIsUserEdited, createdAt: createdAt,
            startedAt: startedAt, endedAt: endedAt,
            segments: segments.map { seg in
                CloudMeetingRecord.Segment(
                    index: seg.index, startedAt: seg.startedAt, endedAt: seg.endedAt,
                    endReason: seg.endReason?.rawValue,
                    utterances: seg.utterances.map {
                        CloudMeetingRecord.Utterance(text: $0.text, startMs: $0.startMs,
                                                     endMs: $0.endMs, speakerID: $0.speakerID)
                    },
                    isResolved: seg.isResolved)
            },
            isFinalTranscript: isFinalTranscript, summary: summary, summaryRaw: summaryRaw,
            editedTranscriptText: editedTranscriptText, speakerNames: speakerNames,
            state: state.rawValue, speakerInfoEnabled: speakerInfoEnabled, updatedAt: updatedAt)
    }

    /// `preservingAudioFrom`:合并时按 id 从本机现有记录里回填 audioFileName——同一台设备
    /// 拉取自己刚推上去的记录时,音频关联不能凭空消失(`HistoryStore.replaceAll` 同一模式)。
    init(fromCloud cloud: CloudMeetingRecord, preservingAudioFrom existing: MeetingRecord?) {
        let localByIndex = Dictionary((existing?.segments ?? []).map { ($0.index, $0) },
                                      uniquingKeysWith: { first, _ in first })
        self.init(
            id: cloud.id, title: cloud.title, titleIsUserEdited: cloud.titleIsUserEdited,
            createdAt: cloud.createdAt, startedAt: cloud.startedAt, endedAt: cloud.endedAt,
            segments: cloud.segments.map { seg in
                MeetingSegment(
                    id: localByIndex[seg.index]?.id ?? UUID(), index: seg.index, startedAt: seg.startedAt, endedAt: seg.endedAt,
                    audioFileName: localByIndex[seg.index]?.audioFileName,
                    utterances: seg.utterances.map {
                        MeetingUtterance(text: $0.text, startMs: $0.startMs, endMs: $0.endMs,
                                         speakerID: $0.speakerID, isFinal: true)
                    },
                    endReason: seg.endReason.flatMap(MeetingSegmentEndReason.init(rawValue:)),
                    isResolved: seg.isResolved)
            },
            isFinalTranscript: cloud.isFinalTranscript, summary: cloud.summary, summaryRaw: cloud.summaryRaw,
            editedTranscriptText: cloud.editedTranscriptText, speakerNames: cloud.speakerNames,
            // 远端设备没有真的在录:云端 state 若是 "recording",本机只应展示为"草稿",
            // 不能在一台没有麦克风会话的设备上显示"录音中"的实时态。
            state: cloud.state == MeetingProcessingState.recording.rawValue
                ? .transcriptDraft
                : (MeetingProcessingState(rawValue: cloud.state) ?? .transcriptDraft),
            speakerInfoEnabled: cloud.speakerInfoEnabled, updatedAt: cloud.updatedAt)
    }
}

/// 会议记录 iCloud 同步(仅文本,音频不上云)。文件格式、墓碑与合并语义由 core 统一,
/// 与 `CloudHistorySync` 是同一套约定的第二份实例——独立子目录、独立墓碑,不与历史记录混放。
enum CloudMeetingSync {
    static let containerID = CloudHistorySync.containerID
    private static let folderName = "Meetings"

    static func meetingsFolder() -> URL? {
        guard let documents = CloudHistorySync.documentsFolder() else { return nil }
        let dir = documents.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    static var isAvailable: Bool { meetingsFolder() != nil }

    struct PushResult {
        var written = 0
        var failed = 0
        var succeeded: Bool { failed == 0 }
    }

    @discardableResult
    static func push(_ r: MeetingRecord) -> Bool {
        guard let dir = meetingsFolder() else { return false }
        let rec = r.cloudRecord()
        let url = dir.appendingPathComponent(rec.fileName)
        if let data = try? Data(contentsOf: url), let existing = try? CloudMeetingRecord.decode(data) {
            if existing.deletedAt != nil { return true }
            // 文件同步没有服务端 CAS；至少不能让离线旧设备把更新过的云端记录直接覆盖。
            if existing.updatedAt > rec.updatedAt { return true }
        }
        guard let data = try? rec.encoded() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func pushDeletion(id: UUID, createdAt: Date, deletedAt: Date) -> Bool {
        guard let dir = meetingsFolder() else { return false }
        let rec = CloudMeetingRecord.tombstone(id: id, createdAt: createdAt, deletedAt: deletedAt)
        let url = dir.appendingPathComponent(rec.fileName)
        if let data = try? Data(contentsOf: url),
           let existing = try? CloudMeetingRecord.decode(data),
           let existingDeletedAt = existing.deletedAt, existingDeletedAt >= deletedAt {
            return true
        }
        guard let data = try? rec.encoded() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func pushAll(_ records: [MeetingRecord], deletions: [(id: UUID, createdAt: Date, deletedAt: Date)] = []) -> PushResult {
        var result = PushResult()
        for record in records {
            if push(record) { result.written += 1 } else { result.failed += 1 }
        }
        for d in deletions {
            if pushDeletion(id: d.id, createdAt: d.createdAt, deletedAt: d.deletedAt) { result.written += 1 } else { result.failed += 1 }
        }
        return result
    }

    struct PullResult {
        var merged: [MeetingRecord]?
        var cloudFiles = 0
        var inserted = 0
        var updated = 0
        var removed = 0
        var deletions: [UUID: Date] = [:]
        var pendingDownload = 0
    }

    static func pull(into local: [MeetingRecord], localDeletions: [UUID: Date] = [:]) -> PullResult? {
        guard let dir = meetingsFolder() else { return nil }
        var result = PullResult()
        var cloudRecords: [CloudMeetingRecord] = []
        let resourceKeys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return result
        }
        for fileURL in files {
            if fileURL.lastPathComponent.hasPrefix(".") || fileURL.lastPathComponent.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                result.pendingDownload += 1
                continue
            }
            guard fileURL.pathExtension == "json" else { continue }
            if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
               values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                result.pendingDownload += 1
                continue
            }
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize, size > 4 * 1024 * 1024 { continue } // 会议转写比历史条目长,放宽单文件上限
            guard let data = try? Data(contentsOf: fileURL),
                  let rec = try? CloudMeetingRecord.decode(data) else { continue }
            cloudRecords.append(rec)
        }
        result.cloudFiles = cloudRecords.count
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let outcome = CloudMeetingMerge.merge(local: local, localDeletions: localDeletions, cloud: cloudRecords) { rec in
            MeetingRecord(fromCloud: rec, preservingAudioFrom: localByID[rec.id])
        }
        result.merged = outcome.records
        result.inserted = outcome.inserted
        result.updated = outcome.updated
        result.removed = outcome.removed
        result.deletions = outcome.deletions
        return result
    }
}
