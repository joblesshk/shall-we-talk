import Foundation

enum CloudHistorySync {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swt-config-" + UUID().uuidString)
    static func documentsFolder() -> URL? { directory }
}

final class SettingsStore {
    var volcAppId = ""
    var llmProviderRaw = ""
    var llmBaseURLString = ""
    var llmModel = ""
    var arkModel = ""
    static func canonicalDeepSeekModel(_ model: String, providerRaw: String) -> String { model }
}

@main enum CredentialSyncSmoke {
    static func main() throws {
        defer { try? FileManager.default.removeItem(at: CloudHistorySync.directory) }
        let snapshot = CredentialDocument(llmProvider: "synthetic", llmModel: "model-a")
        precondition(CredentialSyncCoordinator.pushIfChanged(snapshot) != nil)
        let file = CloudHistorySync.directory.appendingPathComponent("Credentials/credentials.json")
        let valid = try Data(contentsOf: file)
        precondition(CredentialSyncCoordinator.pushIfChanged(snapshot) == nil)
        let unchanged = try Data(contentsOf: file)
        precondition(valid == unchanged)
        let damaged = Data("incomplete-json".utf8)
        try damaged.write(to: file)
        precondition(CredentialSyncCoordinator.pushIfChanged(snapshot) == nil)
        let preserved = try Data(contentsOf: file)
        precondition(preserved == damaged, "A decode failure must never be treated as an absent file")
        try valid.write(to: file)
        let updated = CredentialDocument(llmProvider: "synthetic", llmModel: "model-b")
        precondition(CredentialSyncCoordinator.pushIfChanged(updated) != nil)
        precondition(CredentialSyncCoordinator.remote()?.llmModel == "model-b")
        print("PASS: configuration creation, unchanged skip, corrupt-file preservation and recovery")
    }
}
