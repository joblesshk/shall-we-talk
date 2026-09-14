import Foundation

/// 非敏感服务配置的 iCloud 同步。API token 只保存在本机钥匙串，不进入 iCloud Drive。
///
/// 解决的是换设备时恢复端点、模型等非敏感配置。每台设备首次使用仍需自行录入 token；
/// 这是避免 iCloud Drive 文件或分发二进制泄露 API 密钥的明确安全边界。
enum CredentialSyncBridge {
    static let containerID = CloudHistorySync.containerID
    private static let folderName = "Credentials"
    private static let fileName = "credentials.json"

    private static func documentsFolder() -> URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
        return base.appendingPathComponent("Documents", isDirectory: true)
    }

    private static func folder() -> URL? {
        guard let documents = documentsFolder() else { return nil }
        let dir = documents.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    static var isAvailable: Bool { folder() != nil }

    private static var fileURL: URL? { folder()?.appendingPathComponent(fileName) }

    /// 未下载的占位文件只触发下载后返回 nil,绝不同步等待——iCloud 文件 I/O 可能长时间
    /// 阻塞,这条是 0x8BADF00D watchdog 那次事故留下的硬规矩(§11)。
    static func pull() -> CredentialDocument? {
        guard let url = fileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CredentialDocument.self, from: data)
    }

    @discardableResult
    static func write(_ document: CredentialDocument) -> Bool {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(document) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// 云端配置文档。保留旧 token 字段只为兼容解码，新的写入永远不填它们。
struct CredentialDocument: Codable, Equatable {
    var updatedAt: TimeInterval = 0
    var volcWsURL: String?
    var volcAppId: String?
    var volcAccessToken: String?
    var volcResourceId: String?
    var llmProvider: String?
    var llmBaseURL: String?
    var llmModel: String?
    var llmKey: String?
    var arkModel: String?
    var arkKey: String?

    /// 判空用:一份没有服务配置的文档不值得写上去,也不该覆盖本机。
    var hasAnyCredential: Bool {
        [volcAppId, volcWsURL, llmProvider, llmBaseURL, llmModel, arkModel]
            .contains { !($0 ?? "").isEmpty }
    }
}

/// 拉取 / 推送的胶水层。非敏感配置以时间戳做最后写入者胜；token 不参与比较或覆盖。
enum CredentialSyncCoordinator {
    private static let syncedAtKey = "credentialsSyncedAt"
    private static let writeLock = NSLock()

    private static var localUpdatedAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: syncedAtKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncedAtKey) }
    }

    private static func snapshot(of settings: MobileSettingsStore) -> CredentialDocument {
        CredentialDocument(
            updatedAt: localUpdatedAt,
            volcWsURL: settings.volcWsURLString,
            volcAppId: settings.volcAppId,
            volcAccessToken: nil,
            volcResourceId: settings.volcResourceId,
            llmProvider: settings.llmProviderRaw,
            llmBaseURL: settings.llmBaseURLString,
            llmModel: settings.llmModel,
            llmKey: nil,
            arkModel: settings.arkModel,
            arkKey: nil
        )
    }

    /// **I/O 与应用必须分开**:iCloud 文件读写可能长时间阻塞,绝不能占用 MainActor
    /// (§11 的 0x8BADF00D watchdog 事故就是这么来的)。这个方法在后台线程调用。
    nonisolated static func loadRemote() -> CredentialDocument? {
        guard let remote = CredentialSyncBridge.pull(), remote.hasAnyCredential else { return nil }
        return remote
    }

    /// 只在**云端更新**时覆盖本机;逐字段跳过空值,免得云端某个空字段把本机刚填好的值抹掉。
    @MainActor
    @discardableResult
    static func apply(_ remote: CredentialDocument, to settings: MobileSettingsStore) -> Bool {
        guard remote.updatedAt > localUpdatedAt else { return false }
        func apply(_ value: String?, _ assign: (String) -> Void) {
            guard let value, !value.isEmpty else { return }
            assign(value)
        }
        // 旧 iCloud 凭证文档可能仍保存 async。恢复时直接迁移持久化值，不能让旧云端
        // 配置把已经原生使用 nostream 的新安装改回 async。
        apply(remote.volcWsURL) { settings.volcWsURLString = MobileSettingsStore.migratedVolcWsURL($0) }
        apply(remote.volcAppId) { settings.volcAppId = $0 }
        apply(remote.volcResourceId) { settings.volcResourceId = $0 }
        apply(remote.llmProvider) { settings.llmProviderRaw = $0 }
        apply(remote.llmBaseURL) { settings.llmBaseURLString = $0 }
        let remoteProvider = remote.llmProvider ?? settings.llmProviderRaw
        apply(remote.llmModel) {
            settings.llmModel = MobileSettingsStore.canonicalDeepSeekModel($0, providerRaw: remoteProvider)
        }
        apply(remote.arkModel) { settings.arkModel = $0 }
        localUpdatedAt = remote.updatedAt
        DiagLog.log("credSync", "已从 iCloud 恢复凭证")
        return true
    }

    /// 取本机快照供推送。判断"要不要推"需要读云端,那一步同样在后台线程做,
    /// 所以这里只负责取值,比对与写入都在 `pushIfChanged` 里。
    @MainActor
    static func localSnapshot(of settings: MobileSettingsStore) -> CredentialDocument? {
        let current = snapshot(of: settings)
        return current.hasAnyCredential ? current : nil
    }

    /// 本机凭证与云端不同就推一次。不逐个字段挂监听,而是比对整份快照——凭证的编辑
    /// 入口有好几个(设置页多个输入框),挂监听既啰嗦又容易漏。**整个方法在后台线程调用。**
    nonisolated static func pushIfChanged(_ snapshot: CredentialDocument) -> TimeInterval? {
        writeLock.lock()
        defer { writeLock.unlock() }
        var current = snapshot
        var lastPushed = CredentialSyncBridge.pull() ?? CredentialDocument()
        // 只比对凭证内容本身,时间戳不参与——否则每次都会判定为"变了"。
        current.updatedAt = 0
        lastPushed.updatedAt = 0
        guard current != lastPushed else { return nil }
        current.updatedAt = Date().timeIntervalSince1970
        guard CredentialSyncBridge.write(current) else {
            DiagLog.log("credSync", "推送失败(iCloud 不可用或写入被拒)")
            return nil
        }
        DiagLog.log("credSync", "凭证已推送到 iCloud")
        return current.updatedAt
    }

    @MainActor
    static func markPushed(at timestamp: TimeInterval) {
        localUpdatedAt = timestamp
    }
}
