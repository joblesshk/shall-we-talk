import Foundation
import ShallWeTalkCore

/// 个人词典 + 纠错对的 iCloud Documents 同步桥。与 `CloudHistorySync` 共用同一 iCloud
/// 容器(`iCloud.org.example.voicepen`),独立文件 `Documents/Dictionary/dictionary-sync.json`,
/// 不与 `History/` 下的历史记录同步互相干扰。
///
/// 平台差异与 `CloudHistorySync` 完全一致:
/// - iOS:官方 Ubiquity API(需 iCloud Documents capability,已随 App.iCloud.entitlements 具备)
/// - macOS:App 未沙盒,直接读写 Mobile Documents 下的容器镜像路径,同步交给系统 bird 守护进程
///
/// 历史教训(§11.1 0x8BADF00D):枚举/读写必须离开 MainActor;未下载的占位文件只触发下载后
/// 跳过,绝不同步等待。本类型自身不做线程切换——调用方(`DictionarySyncCoordinator`)必须
/// 保证在非 MainActor 上下文调用 `pull()` / `write()`,与 `CloudHistorySync` 同一约定。
enum DictionarySyncBridge {
    static let containerID = CloudHistorySync.containerID
    private static let fileName = "dictionary-sync.json"

    private static func documentsFolder() -> URL? {
        #if os(macOS)
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/" + containerID.replacingOccurrences(of: ".", with: "~"),
                                    isDirectory: true)
        guard FileManager.default.fileExists(atPath: container.path) else { return nil }
        return container.appendingPathComponent("Documents", isDirectory: true)
        #else
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        return base.appendingPathComponent("Documents", isDirectory: true)
        #endif
    }

    /// 规范词典目录(写入永远走这里;拉取还会扫 "Dictionary 2" 等 iCloud 冲突改名变体,
    /// 与 `CloudHistorySync.historyFolder()` 同一根因修复,见 2026-07-18 实测)。
    private static func dictionaryFolder() -> URL? {
        guard let documents = documentsFolder() else { return nil }
        let dir = documents.appendingPathComponent(CloudDictionaryLayout.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private static var fileURL: URL? { dictionaryFolder()?.appendingPathComponent(fileName) }

    static var isAvailable: Bool { dictionaryFolder() != nil }

    /// `pull()` 的结果:必须把"远端文件还没下载完"和"远端本来就没有数据"区分开——
    /// 二者都表现为读不到内容,但前者绝不能被 `syncAndMerge` 当成空文档写回覆盖掉云端
    /// 真正的数据(2026-08-17 真机实测教训:两台设备几乎同时同步,B 设备本地缓存的
    /// 云端文件还没跟上 A 设备刚写入的新版本,读到"未下载"却当空文档合并写回,
    /// 把 A 刚同步上去的 61 个词整个覆盖掉了)。
    enum PullOutcome {
        case data(DictionarySyncDocument)
        case empty      // 规范目录 + 变体目录都不存在任何同步文件:确实从未同步过,可放心当空文档合并
        case pending    // 至少一个变体的文件存在但仍是占位符(下载中):本轮不能写,避免用不完整数据覆盖云端
    }

    private enum ReadOutcome {
        case found(DictionarySyncDocument)
        case pending
        case missing
    }

    /// 读取单个变体目录下的文档,区分"文件不存在/损坏"(missing,可忽略)与
    /// "文件存在但还没下载完成"(pending,调用方必须整轮跳过写入)。
    private static func readDocument(at url: URL) -> ReadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        let resourceKeys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]
        if let values = try? url.resourceValues(forKeys: resourceKeys) {
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return .pending
            }
            // 词典/纠错同步文件应是几十 KB 级别的小 JSON；异常大文件不整块载入内存,当损坏处理。
            if let size = values.fileSize, size > 2 * 1024 * 1024 { return .missing }
        }
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(DictionarySyncDocument.self, from: data) else {
            return .missing
        }
        return .found(doc)
    }

    /// 读取云端合并文档:扫描规范目录 + "Dictionary 2" 等冲突变体,把各自的
    /// `dictionary-sync.json` 合并成一份(与 History 的变体目录扫描同一根因修复)。
    /// 只要任一变体处于"下载中",整体返回 `.pending`——宁可这一轮不同步,也不能
    /// 用尚未追上的本机缓存覆盖云端已有数据。
    static func pull() -> PullOutcome {
        guard let documents = documentsFolder() else { return .empty }
        _ = dictionaryFolder() // 确保规范目录存在,供本轮 write() 使用
        let folders = CloudDictionaryLayout.dictionaryFolders(inDocuments: documents)
        guard !folders.isEmpty else { return .empty }

        var docs: [DictionarySyncDocument] = []
        var sawPending = false
        for folder in folders {
            switch readDocument(at: folder.appendingPathComponent(fileName)) {
            case .found(let doc): docs.append(doc)
            case .pending: sawPending = true
            case .missing: break
            }
        }
        if sawPending { return .pending }
        guard let merged = DictionarySync.mergeAll(docs) else { return .empty }
        return .data(merged)
    }

    /// 原子写入合并后的文档(只写规范目录)。
    static func write(_ doc: DictionarySyncDocument) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(doc) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            CoreDiagLog.log("dictSync", "云端词典写入失败: \(error.localizedDescription)")
            return false
        }
    }
}
