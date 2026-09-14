import Foundation

/// A write-ahead snapshot makes the two legacy JSON files one recoverable commit.
/// Their formats remain unchanged for existing exports and local tools. A journal
/// is removed only after both files have been replaced successfully.
public struct HistoryPersistence<Record: Codable> {
    public struct State: Codable {
        public var records: [Record]
        public var deletions: [String: Date]

        public init(records: [Record], deletions: [String: Date]) {
            self.records = records
            self.deletions = deletions
        }
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let state: State
    }

    private let directory: URL
    private let read: (URL) throws -> Data
    private let write: (Data, URL) throws -> Void
    private let remove: (URL) throws -> Void

    public init(directory: URL,
                read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
                write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.directory = directory
        self.read = read
        self.write = write
        self.remove = remove
    }

    public func load() throws -> State {
        let decoder = JSONDecoder()
        if let pending = try readIfPresent("history-transaction.json") {
            let journal = try decoder.decode(Journal.self, from: pending)
            guard journal.schemaVersion == 1 else {
                throw CocoaError(.coderReadCorrupt)
            }
            // Never fall back to potentially mixed legacy files if the journal is
            // unreadable. Keep the original bytes intact for explicit recovery.
            return journal.state
        }
        let records = try readIfPresent("history.json").map { try decoder.decode([Record].self, from: $0) } ?? []
        let deletions = try readIfPresent("history-deletions.json").map {
            try decoder.decode([String: Date].self, from: $0)
        } ?? [:]
        return State(records: records, deletions: deletions)
    }

    public func save(_ state: State) throws {
        let encoder = JSONEncoder()
        // Encode everything before the first write: an encoding error must not
        // leave a journal which can never be materialized in the legacy format.
        let records = try encoder.encode(state.records)
        let deletions = try encoder.encode(state.deletions)
        // Reuse the already encoded values: the journal contains the same full
        // snapshot, so encoding every record twice adds avoidable UI-thread work.
        // Only fixed JSON punctuation is assembled here; all user data still
        // goes through JSONEncoder, preserving escaping and the version-1 schema.
        var journal = Data("{\"schemaVersion\":1,\"state\":{\"records\":".utf8)
        journal.append(records)
        journal.append(Data(",\"deletions\":".utf8))
        journal.append(deletions)
        journal.append(Data("}}".utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(journal, directory.appendingPathComponent("history-transaction.json"))
        try write(records, directory.appendingPathComponent("history.json"))
        try write(deletions, directory.appendingPathComponent("history-deletions.json"))
        try remove(directory.appendingPathComponent("history-transaction.json"))
    }

    private func readIfPresent(_ name: String) throws -> Data? {
        do { return try read(directory.appendingPathComponent(name)) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                return nil
            }
            throw error
        }
    }
}
