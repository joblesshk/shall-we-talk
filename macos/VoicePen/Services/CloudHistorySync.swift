import Foundation
import ShallWeTalkCore

/// 历史记录 iCloud 同步(仅文本,音频不上云)
/// 结构:iCloud 容器 Documents/History/ 下每条记录一个 <UUID>.json，编辑与删除会更新该文件
/// (文件格式/合并语义在 core.CloudHistoryRecord / core.CloudHistoryMerge,与 iOS 同源)
/// 合并:按 id 取并集；新版最终稿按修订版本比较，旧格式沿用兼容规则
enum CloudHistorySync {
    static let containerID = "iCloud.org.example.voicepen"
    /// 同进程的 read/compare/write 串行化；此锁不保证跨设备云端事务隔离。
    private static let mutationLock = NSLock()

    /// 容器 Documents 目录
    /// macOS App 未沙盒(辅助功能/粘贴模拟所需),无法用 iCloud entitlement,
    /// 直接读写 Mobile Documents 下的容器镜像路径,同步由系统 bird 守护进程完成。
    /// 注意(2026-07-18 实测教训):bird 只在本机安装有声明该容器的 App 时才同步该容器;
    /// 否则写入只落在本地镜像,不会上传,甚至会被 bird 的容器清理直接删掉。
    static func documentsFolder() -> URL? {
        let fm = FileManager.default
        guard fm.ubiquityIdentityToken != nil else { return nil }
        let container = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/" + containerID.replacingOccurrences(of: ".", with: "~"),
                                    isDirectory: true)
        guard fm.fileExists(atPath: container.path) else { return nil }
        let dir = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// 规范历史目录(写入永远走这里;拉取还会扫 "History 2" 等 iCloud 冲突改名变体)
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

    /// 推送单条(新增或编辑/重识别后调用,开销一个小文件写入)。与已存在的云文件做
    /// 字段级合并(`CloudHistoryMerge.mergeForPush`):编辑维度(finalText/revisions/
    /// editVersion)与正文维度(rawText/cleanText/recognitionVersion)分别按各自版本
    /// 判断是否采用,不用整条记录二选一覆盖——否则较旧的异步重识别任务可能覆盖新编辑,
    /// 反之亦然(2026-09-06 回归审查 #2)。两个维度都不需要更新时不写文件,直接返回成功。
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

    /// 首次开启同步时全量补推
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

    /// 把规范云目录里缺失的本地记录补传上去(双向同步的推方向,按钮/启动时调用)。
    /// 返回实际写入条数;目录不可用返回 0。
    static func pushMissing(_ records: [DictationRecord], deletions: [UUID: Date] = [:]) -> PushResult {
        guard let dir = historyFolder(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)
        else { return PushResult(failed: 1) }
        let existing = Set(files.map { $0.deletingPathExtension().lastPathComponent.uppercased() })
        var result = PushResult()
        for (id, deletedAt) in deletions {
            if pushDeletion(id: id, deletedAt: deletedAt) { result.written += 1 } else { result.failed += 1 }
        }
        for r in records where !existing.contains(r.id.uuidString) {
            if push(r) { result.written += 1 } else { result.failed += 1 }
        }
        return result
    }

    struct PullResult {
        /// 合并后的完整列表;nil = 云端没有带来任何变化
        var merged: [DictationRecord]?
        /// 回主线程后交给 HistoryStore 基于最新本地状态重做合并。
        var cloudRecords: [CloudHistoryRecord] = []
        var cloudFiles = 0       // 本轮实际解码成功的云端记录文件数
        var inserted = 0         // 新增条数
        var adoptedFinal = 0     // 接受云端最终稿的条数
        var removed = 0          // 接受云端墓碑、删除本机记录的条数
        var deletions: [UUID: Date] = [:]
        var pendingDownload = 0  // 仅触发下载、待下轮合并的文件数
    }

    /// 拉取云端并与本地合并;iCloud 目录不可用返回 nil。
    /// 扫描规范目录 + "History 2" 等冲突变体(bird 在容器清理/重建窗口可能把云端目录
    /// 改名落地,只读字面量目录会导致存量记录整体"消失",见 2026-07-18 根因排查)。
    static func pull(into local: [DictationRecord], localDeletions: [UUID: Date] = [:]) -> PullResult? {
        guard let documents = documentsFolder() else { return nil }
        _ = historyFolder() // 确保规范目录存在,供本轮 pushMissing / 后续写入
        var result = PullResult()
        var cloudRecords: [CloudHistoryRecord] = []

        let resourceKeys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey
        ]
        for dir in CloudHistoryLayout.historyFolders(inDocuments: documents) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                           includingPropertiesForKeys: nil)
            else { continue }
            for f in files {
                // .icloud 占位文件 = 尚未下载:触发下载,下次同步再合并
                if f.lastPathComponent.hasPrefix(".") || f.lastPathComponent.hasSuffix(".icloud") {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: f)
                    result.pendingDownload += 1
                    continue
                }
                guard f.pathExtension == "json" else { continue }

                // 逻辑文件名可能仍是 .json,但内容尚未从 iCloud 落地。直接读取会同步等待下载;
                // 本轮只触发下载并跳过,下次同步再合并。
                if let values = try? f.resourceValues(forKeys: resourceKeys),
                   values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: f)
                    result.pendingDownload += 1
                    continue
                }
                // 单条历史应是小 JSON;异常大文件不整块载入内存。
                if let values = try? f.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize, size > 2 * 1024 * 1024 {
                    continue
                }
                guard let data = try? Data(contentsOf: f),
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

/// 让 macOS 端的 DictationRecord 直接参与 core 的合并逻辑(id/date/finalText 已具备)。
extension DictationRecord: CloudMergeableHistoryRecord {}
