import Foundation
import ShallWeTalkCore

/// 历史记录 iCloud 同步（仅文本，音频不上云）。文件格式、墓碑与合并语义由 core 统一。
enum CloudHistorySync {
    static let containerID = "iCloud.org.example.voicepen"
    /// 同一进程内把 read/compare/atomic-write 串成一个临界区，避免较早启动的异步 push
    /// 在新编辑或墓碑之后完成。跨设备版本比较在拉取时执行；此锁不保证云端事务隔离。
    private static let mutationLock = NSLock()

    static func documentsFolder() -> URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let dir = base.appendingPathComponent("Documents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    static func historyFolder() -> URL? {
        guard let documents = documentsFolder() else { return nil }
        let dir = documents.appendingPathComponent(CloudHistoryLayout.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    static var isAvailable: Bool { historyFolder() != nil }

    struct PushResult {
        var written = 0
        var failed = 0
        var succeeded: Bool { failed == 0 }
    }

    /// 推送单条(新增或编辑/重识别后调用)。与已存在的云文件做字段级合并
    /// (`CloudHistoryMerge.mergeForPush`):编辑维度(finalText/revisions/editVersion)与
    /// 正文维度(rawText/cleanText/recognitionVersion)分别按各自版本判断是否采用,
    /// 不用整条记录二选一覆盖——否则较旧的异步重识别任务可能覆盖新编辑,反之亦然
    /// (2026-09-06 回归审查 #2)。两个维度都不需要更新时不写文件,直接返回成功。
    @discardableResult
    static func push(_ r: DictationRecord) -> Bool {
        guard let dir = historyFolder() else { return false }
        let url = dir.appendingPathComponent("\(r.id.uuidString).json")
        let incoming = CloudHistoryRecord(id: r.id, date: r.date, rawText: r.rawText,
                                          cleanText: r.cleanText, finalText: r.finalText,
                                          revisions: r.revisions, editVersion: r.editVersion,
                                          recognitionVersion: r.recognitionVersion)
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var toWrite = incoming
        if let existingData = try? Data(contentsOf: url),
           let existing = try? CloudHistoryRecord.decode(existingData) {
            guard let merged = CloudHistoryMerge.mergeForPush(existing: existing, incoming: incoming)
            else { return true }
            toWrite = merged
        }
        guard let data = try? toWrite.encoded() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func pushDeletion(id: UUID, deletedAt: Date) -> Bool {
        guard let dir = historyFolder() else { return false }
        let rec = CloudHistoryRecord.tombstone(id: id, originalDate: deletedAt, deletedAt: deletedAt)
        guard let data = try? rec.encoded() else { return false }
        let url = dir.appendingPathComponent(rec.fileName)
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if let existingData = try? Data(contentsOf: url),
           let existing = try? CloudHistoryRecord.decode(existingData),
           let existingDeletedAt = existing.deletedAt, existingDeletedAt >= deletedAt {
            return true
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func pushAll(_ records: [DictationRecord], deletions: [UUID: Date] = [:]) -> PushResult {
        var result = PushResult()
        for record in records {
            if push(record) { result.written += 1 } else { result.failed += 1 }
        }
        for (id, deletedAt) in deletions {
            if pushDeletion(id: id, deletedAt: deletedAt) { result.written += 1 } else { result.failed += 1 }
        }
        return result
    }

    struct PullResult {
        var merged: [DictationRecord]?
        /// 提交时交给 HistoryStore 基于最新本地状态重做合并，避免旧快照覆盖新改动。
        var cloudRecords: [CloudHistoryRecord] = []
        var cloudFiles = 0
        var inserted = 0
        var adoptedFinal = 0
        var removed = 0
        var deletions: [UUID: Date] = [:]
        var pendingDownload = 0
    }

    static func pull(into local: [DictationRecord],
                     localDeletions: [UUID: Date] = [:]) -> PullResult? {
        guard let documents = documentsFolder() else { return nil }
        _ = historyFolder()
        var result = PullResult()
        var cloudRecords: [CloudHistoryRecord] = []
        let resourceKeys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey
        ]

        for dir in CloudHistoryLayout.historyFolders(inDocuments: documents) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                if file.lastPathComponent.hasPrefix(".") || file.lastPathComponent.hasSuffix(".icloud") {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    result.pendingDownload += 1
                    continue
                }
                guard file.pathExtension == "json" else { continue }
                if let values = try? file.resourceValues(forKeys: resourceKeys),
                   values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    result.pendingDownload += 1
                    continue
                }
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize, size > 2 * 1024 * 1024 { continue }
                guard let data = try? Data(contentsOf: file),
                      let rec = try? CloudHistoryRecord.decode(data) else { continue }
                cloudRecords.append(rec)
            }
        }
        result.cloudFiles = cloudRecords.count
        result.cloudRecords = cloudRecords
        let outcome = CloudHistoryMerge.merge(
            local: local, localDeletions: localDeletions, cloud: cloudRecords) { rec in
                DictationRecord(id: rec.id, date: rec.date, rawText: rec.rawText,
                                cleanText: rec.cleanText, finalText: rec.finalText,
                                audioFileName: nil, revisions: rec.revisions,
                                editVersion: rec.editVersion, recognitionVersion: rec.recognitionVersion)
            }
        result.merged = outcome.records
        result.inserted = outcome.inserted
        result.adoptedFinal = outcome.adoptedFinal
        result.removed = outcome.removed
        result.deletions = outcome.deletions
        return result
    }
}

extension DictationRecord: CloudMergeableHistoryRecord {}
