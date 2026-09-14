import Foundation

/// 与 iOS 使用同一份非敏感服务配置文件。API token 只保存在各设备本机钥匙串。
private enum MacCredentialSyncBridge {
    private static let fileName = "credentials.json"

    private static func folder() -> URL? {
        guard let documents = CloudHistorySync.documentsFolder() else { return nil }
        let url = documents.appendingPathComponent("Credentials", isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
        catch { return nil }
    }

    static func load() -> CredentialDocument? {
        try? readForWrite()
    }

    /// nil means confirmed absent; unreadable/pending/corrupt is an error.
    static func readForWrite() throws -> CredentialDocument? {
        guard let url = folder()?.appendingPathComponent(fileName) else {
            throw CocoaError(.fileReadUnknown)
        }
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw CocoaError(.fileReadUnknown)
        }
        return try JSONDecoder().decode(CredentialDocument.self, from: Data(contentsOf: url))
    }

    static func write(_ document: CredentialDocument) -> Bool {
        guard let url = folder()?.appendingPathComponent(fileName),
              let data = try? JSONEncoder().encode(document) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }
}

/// 保留 iOS `CredentialDocument` 的旧字段用于兼容解码；Mac 主听写的端点和资源已
/// 固定，不再写入或采纳这些字段。
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

    var hasAnyCredential: Bool {
        [volcAppId, volcWsURL, llmProvider, llmBaseURL, llmModel, arkModel].contains { !($0 ?? "").isEmpty }
    }
}

enum CredentialSyncCoordinator {
    private static let timestampKey = "credentialsSyncedAt"
    private static let writeLock = NSLock()

    private static var localUpdatedAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: timestampKey) }
        set { UserDefaults.standard.set(newValue, forKey: timestampKey) }
    }

    @MainActor static func localSnapshot(of settings: SettingsStore) -> CredentialDocument? {
        let result = CredentialDocument(updatedAt: localUpdatedAt,
                                        volcWsURL: nil,
                                        volcAppId: settings.volcAppId,
                                        volcAccessToken: nil,
                                        volcResourceId: nil,
                                        llmProvider: settings.llmProviderRaw,
                                        llmBaseURL: settings.llmBaseURLString,
                                        llmModel: settings.llmModel,
                                        llmKey: nil,
                                        arkModel: settings.arkModel,
                                        arkKey: nil)
        return result.hasAnyCredential ? result : nil
    }

    @MainActor static func applyIfNewer(_ remote: CredentialDocument, to settings: SettingsStore) -> Bool {
        guard remote.hasAnyCredential, remote.updatedAt > localUpdatedAt else { return false }
        func assign(_ value: String?, _ set: (String) -> Void) { if let value, !value.isEmpty { set(value) } }
        assign(remote.volcAppId) { settings.volcAppId = $0 }
        assign(remote.llmProvider) { settings.llmProviderRaw = $0 }
        assign(remote.llmBaseURL) { settings.llmBaseURLString = $0 }
        let remoteProvider = remote.llmProvider ?? settings.llmProviderRaw
        assign(remote.llmModel) {
            settings.llmModel = SettingsStore.canonicalDeepSeekModel($0, providerRaw: remoteProvider)
        }
        assign(remote.arkModel) { settings.arkModel = $0 }
        localUpdatedAt = remote.updatedAt
        return true
    }

    nonisolated static func pushIfChanged(_ snapshot: CredentialDocument) -> TimeInterval? {
        writeLock.lock()
        defer { writeLock.unlock() }
        var candidate = snapshot
        let read: CredentialDocument?
        do { read = try MacCredentialSyncBridge.readForWrite() }
        catch { return nil }
        var existing = read ?? CredentialDocument()
        candidate.updatedAt = 0; existing.updatedAt = 0
        guard candidate != existing else { return nil }
        candidate.updatedAt = Date().timeIntervalSince1970
        return MacCredentialSyncBridge.write(candidate) ? candidate.updatedAt : nil
    }

    @MainActor static func markPushed(_ timestamp: TimeInterval) { localUpdatedAt = timestamp }
    nonisolated static func remote() -> CredentialDocument? { MacCredentialSyncBridge.load() }
}
