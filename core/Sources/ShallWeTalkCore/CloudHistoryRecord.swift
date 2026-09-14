import Foundation

/// 一次语音修改的版本记录(语音二次修改-执行方略.md v2 §2)。放在 core 而不是 iOS 端,
/// 供两端 `DictationRecord` 与 `CloudHistoryRecord` 共用,与 `LearnedCorrection` 同样的做法。
public struct EditRevision: Codable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
    public let instructionRaw: String
    public let before: String
    public let after: String
    public var audioFileName: String?

    public init(id: UUID = UUID(), at: Date = Date(), instructionRaw: String,
               before: String, after: String, audioFileName: String? = nil) {
        self.id = id
        self.at = at
        self.instructionRaw = instructionRaw
        self.before = before
        self.after = after
        self.audioFileName = audioFileName
    }
}

/// `finalText` 与 `revisions` 作为一个整体的同步版本。`counter` 是每条记录的
/// Lamport 修订号；同号并发时依次比较更新时间与设备 ID，保证所有设备作出同一选择。
/// 整体为 Optional，使旧的五字段云文件与既有本地 history.json 无需迁移即可解码。
public struct HistoryEditVersion: Codable, Equatable, Sendable, Comparable {
    public let counter: UInt64
    public let updatedAt: Date
    public let originID: String

    public init(counter: UInt64, updatedAt: Date, originID: String) {
        self.counter = counter
        self.updatedAt = updatedAt
        self.originID = originID
    }

    public static func next(after current: HistoryEditVersion?, originID: String,
                            at: Date = Date()) -> HistoryEditVersion {
        // 云文件是不可信输入；恶意或损坏的 UInt64.max 不能令下一次本地编辑溢出崩溃。
        // 饱和后仍以 updatedAt/originID 决胜，因此后续编辑继续具备确定顺序。
        let currentCounter = current?.counter ?? 0
        let nextCounter = currentCounter == .max ? UInt64.max : currentCounter + 1
        return HistoryEditVersion(counter: nextCounter,
                           updatedAt: at, originID: originID)
    }

    public static func < (lhs: HistoryEditVersion, rhs: HistoryEditVersion) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.originID < rhs.originID
    }
}

/// 跨端历史同步的云端记录:iCloud 容器 `Documents/History/<UUID>.json` 的文件格式。
/// 仅文本,音频与延迟打点(metrics)等本机字段一律不上云。
///
/// 兼容性约定(两端共同遵守,存量 iPhone 数据以此为准,不可破坏):
/// - 文件名:`<UUID uppercased>.json`,每条记录一个文件,追加式天然无冲突;
/// - 日期:JSONEncoder/JSONDecoder 默认策略(timeIntervalSinceReferenceDate 的浮点秒),
///   与 2026-07-11 起的全部存量文件一致,禁止改成 ISO8601 等其它策略;
/// - 前向兼容:解码采用 Codable 默认行为——对方端将来多写的键(如 metrics、
///   recognitionSource)自动忽略;`finalText` 及未来新增键必须是 Optional,缺失取 nil。
public struct CloudHistoryRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public var rawText: String
    public var cleanText: String
    public var finalText: String?
    /// 删除墓碑时间。nil 表示正常记录；非 nil 时文本字段必须为空，避免删除后仍在云端
    /// 保留用户内容。Optional 保证 2026-07-11 起的五字段存量文件继续无损解码。
    public var deletedAt: Date?
    /// 语音修改的版本栈(语音二次修改-执行方略.md v2 §2)。nil = 从未语音修改过,
    /// 与 `finalText`/`deletedAt` 一样是向后兼容的新增键,旧设备解码时缺失取 nil。
    public var revisions: [EditRevision]?
    /// 最终稿与版本栈的原子修订版本。存在时即使 finalText/revisions 都为 nil，也表示
    /// 一次有效的“撤销到整理稿”，可覆盖另一设备上较旧的非空最终稿。
    public var editVersion: HistoryEditVersion?
    /// rawText/cleanText(识别正文)的独立同步版本,与 finalText/revisions 的 editVersion
    /// 分开比较、分别合并:云端重识别只推进这个版本,不会被"整条记录版本号未变"的
    /// 写保护挡在云端之外，也不会让旧的重识别任务覆盖新的用户编辑，反之亦然
    /// (2026-09-06 回归审查 #2)。Optional 保证旧五/六字段云文件继续无损解码；
    /// nil 表示这条记录自创建以来从未被重新识别过，不代表需要升级到最新版本。
    public var recognitionVersion: HistoryEditVersion?

    public init(id: UUID, date: Date, rawText: String, cleanText: String,
                finalText: String? = nil, deletedAt: Date? = nil,
                revisions: [EditRevision]? = nil,
                editVersion: HistoryEditVersion? = nil,
                recognitionVersion: HistoryEditVersion? = nil) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.cleanText = cleanText
        self.finalText = finalText
        self.deletedAt = deletedAt
        self.revisions = revisions
        self.editVersion = editVersion
        self.recognitionVersion = recognitionVersion
    }

    public static func tombstone(id: UUID, originalDate: Date, deletedAt: Date) -> CloudHistoryRecord {
        CloudHistoryRecord(id: id, date: originalDate, rawText: "", cleanText: "",
                           finalText: nil, deletedAt: deletedAt)
    }

    /// 两端统一的解码入口(默认日期策略,未知键忽略)。
    public static func decode(_ data: Data) throws -> CloudHistoryRecord {
        try JSONDecoder().decode(CloudHistoryRecord.self, from: data)
    }

    /// 两端统一的编码入口(默认日期策略)。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// 云端文件名规则(与 iOS 既有存量一致)。
    public var fileName: String { "\(id.uuidString).json" }
}

/// 各端本地历史记录为参与云端合并所需的最小字段。两端的 `DictationRecord` 是分开定义的
/// (各自还带 audioFileName / metrics 等本机字段),让它们分别遵守本协议即可复用同一份
/// 合并逻辑,且合并时本机独有字段原样保留(不经过云端格式的往返,不会丢失)。
public protocol CloudMergeableHistoryRecord {
    var id: UUID { get }
    var date: Date { get }
    var rawText: String { get set }
    var cleanText: String { get set }
    var finalText: String? { get set }
    var revisions: [EditRevision]? { get set }
    var editVersion: HistoryEditVersion? { get set }
    var recognitionVersion: HistoryEditVersion? { get set }
}

/// 历史同步的合并语义(与 iOS `CloudHistorySync.pull` 既有行为一致的纯函数):
/// 按 id 取并集。新版记录按 editVersion 做确定性 LWW；同号并发依次以 updatedAt、
/// originID 决胜。旧格式没有版本时保持历史行为：本地已有编辑优先，本地未编辑才采用
/// 云端编辑。finalText 与 revisions 总是作为同一份修订一起应用，避免撤销栈错配。
public enum CloudHistoryMerge {
    public struct Outcome<R> {
        /// 合并后的完整记录列表(按时间新→旧);nil 表示与本地相比无任何变化。
        public let records: [R]?
        /// 本地此前没有、从云端新增的条数。
        public let inserted: Int
        /// 本地未编辑、接受了云端最终稿的条数(编辑维度:finalText/revisions/editVersion)。
        public let adoptedFinal: Int
        /// 接受了云端识别正文的条数(正文维度:rawText/cleanText/recognitionVersion，
        /// 与 adoptedFinal 各自独立计数,一条记录可能同时命中两者)。
        public let adoptedRecognition: Int
        /// 合并后应在本机持久化的完整删除墓碑集合。
        public let deletions: [UUID: Date]
        /// 本轮因云端墓碑从本机移除的记录条数。
        public let removed: Int
        /// 云端带来了本机此前未知或时间更新的墓碑。
        public let deletionsChanged: Bool
    }

    public static func merge<R: CloudMergeableHistoryRecord>(
        local: [R],
        localDeletions: [UUID: Date] = [:],
        cloud: [CloudHistoryRecord],
        makeRecord: (CloudHistoryRecord) -> R
    ) -> Outcome<R> {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var deletions = localDeletions
        var inserted = 0
        var adoptedFinal = 0
        var adoptedRecognition = 0

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
            if var existing = byID[rec.id] {
                var changed = false
                if shouldAdoptRemoteEdit(local: existing, remote: rec) {
                    existing.finalText = rec.finalText
                    existing.revisions = rec.revisions
                    existing.editVersion = rec.editVersion
                    changed = true
                    adoptedFinal += 1
                }
                // 正文(重识别)与编辑(用户改稿/撤销)各自独立判断、独立采用:两者共用
                // editVersion 会让"重识别没有推进编辑版本"重新变成写保护漏洞，各自
                // 用自己的版本号也才能让旧的重识别任务不覆盖新编辑、反之亦然。
                if shouldAdoptRemoteRecognition(local: existing, remote: rec) {
                    existing.rawText = rec.rawText
                    existing.cleanText = rec.cleanText
                    existing.recognitionVersion = rec.recognitionVersion
                    changed = true
                    adoptedRecognition += 1
                }
                if changed { byID[rec.id] = existing }
            } else {
                byID[rec.id] = makeRecord(rec)
                inserted += 1
            }
        }
        guard inserted > 0 || adoptedFinal > 0 || adoptedRecognition > 0 || removed > 0 else {
            return Outcome(records: nil, inserted: 0, adoptedFinal: 0, adoptedRecognition: 0,
                           deletions: deletions, removed: 0,
                           deletionsChanged: deletionsChanged)
        }
        return Outcome(records: byID.values.sorted { $0.date > $1.date },
                       inserted: inserted, adoptedFinal: adoptedFinal,
                       adoptedRecognition: adoptedRecognition,
                       deletions: deletions, removed: removed,
                       deletionsChanged: deletionsChanged)
    }

    /// 写云文件前是否需要更新(编辑维度或正文维度任一维度需要采用对方即可)。
    /// 保留作为既有布尔判断的兼容入口；实际写入请用 `mergeForPush`，它会做
    /// 字段级合并而不是整条记录二选一覆盖。
    public static func shouldReplaceCloudFile(
        existing: CloudHistoryRecord, with incoming: CloudHistoryRecord
    ) -> Bool {
        mergeForPush(existing: existing, incoming: incoming) != nil
    }

    /// 推送前与已存在的云文件做字段级合并:编辑维度(finalText/revisions/editVersion)
    /// 与正文维度(rawText/cleanText/recognitionVersion)分别按各自版本判断是否采用，
    /// 而不是用单一布尔值决定整条记录二选一覆盖。这样重识别只推进正文版本时不会
    /// 连带滚回另一维度已经写入云端的更新版本,较旧的异步任务在任一维度过期都不能
    /// 覆盖另一维度已经写入的新内容(2026-09-06 回归审查 #2)。墓碑优先级不变:
    /// 已删除的云记录不会被 push 复活。返回 nil 表示两个维度都不需要更新,调用方
    /// 不必写文件。
    public static func mergeForPush(
        existing: CloudHistoryRecord, incoming: CloudHistoryRecord
    ) -> CloudHistoryRecord? {
        guard existing.id == incoming.id else { return nil }
        if existing.deletedAt != nil { return nil }
        if incoming.deletedAt != nil { return incoming }

        var merged = existing
        var changed = false
        if shouldAdoptRemote(localVersion: existing.editVersion, localFinal: existing.finalText,
                             localRevisions: existing.revisions, remoteVersion: incoming.editVersion,
                             remoteFinal: incoming.finalText, remoteRevisions: incoming.revisions) {
            merged.finalText = incoming.finalText
            merged.revisions = incoming.revisions
            merged.editVersion = incoming.editVersion
            changed = true
        }
        if shouldAdoptRemoteVersion(local: existing.recognitionVersion,
                                    remote: incoming.recognitionVersion) {
            merged.rawText = incoming.rawText
            merged.cleanText = incoming.cleanText
            merged.recognitionVersion = incoming.recognitionVersion
            changed = true
        }
        return changed ? merged : nil
    }

    private static func shouldAdoptRemoteEdit<R: CloudMergeableHistoryRecord>(
        local: R, remote: CloudHistoryRecord
    ) -> Bool {
        shouldAdoptRemote(localVersion: local.editVersion,
                          localFinal: local.finalText,
                          localRevisions: local.revisions,
                          remoteVersion: remote.editVersion,
                          remoteFinal: remote.finalText,
                          remoteRevisions: remote.revisions)
    }

    private static func shouldAdoptRemote(
        localVersion: HistoryEditVersion?, localFinal: String?,
        localRevisions: [EditRevision]?, remoteVersion: HistoryEditVersion?,
        remoteFinal: String?, remoteRevisions: [EditRevision]?
    ) -> Bool {
        switch (localVersion, remoteVersion) {
        case let (local?, remote?): return remote > local
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil):
            let localEdited = localFinal != nil || !(localRevisions ?? []).isEmpty
            let remoteEdited = remoteFinal != nil || !(remoteRevisions ?? []).isEmpty
            return !localEdited && remoteEdited
        }
    }

    private static func shouldAdoptRemoteRecognition<R: CloudMergeableHistoryRecord>(
        local: R, remote: CloudHistoryRecord
    ) -> Bool {
        shouldAdoptRemoteVersion(local: local.recognitionVersion, remote: remote.recognitionVersion)
    }

    /// 识别正文版本的确定性决胜规则:与 `HistoryEditVersion.<` 的 (counter, updatedAt,
    /// originID) 顺序一致,只依赖单调修订号,不单独依赖设备时间。两侧都不曾重识别过
    /// (nil, nil)时按兼容规则保持原样，不把旧记录凭空升级成"已重识别"状态。
    private static func shouldAdoptRemoteVersion(
        local: HistoryEditVersion?, remote: HistoryEditVersion?
    ) -> Bool {
        switch (local, remote) {
        case let (local?, remote?): return remote > local
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return false
        }
    }
}

/// 云容器内历史目录的布局工具。
///
/// 背景(2026-07-18 实测):iCloud Drive 的 bird 守护进程在"容器归属 App 被卸载→重装"
/// 的清理/重建窗口里,如果 App 恰好又新建了同名目录,会把云端目录改名为 "History 2"
/// 这类冲突变体落地。两端代码若只读字面量 `Documents/History`,存量记录就会整体"消失"。
/// 拉取时必须把这些变体一并扫进来;写入始终写规范目录 `History`。
public enum CloudHistoryLayout {
    public static let folderName = "History"

    /// `Documents/` 下参与拉取的全部历史目录:规范目录(存在则排最前)+ `History 2`
    /// 等 iCloud 冲突改名变体。只认目录;不存在时返回空数组。
    public static func historyFolders(inDocuments documents: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: documents,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var canonical: [URL] = []
        var variants: [URL] = []
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if name == folderName {
                canonical.append(url)
            } else if name.hasPrefix(folderName + " ") {
                variants.append(url)
            }
        }
        return canonical + variants.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
