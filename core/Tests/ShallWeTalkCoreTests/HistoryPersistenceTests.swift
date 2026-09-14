import XCTest
@testable import ShallWeTalkCore

final class HistoryPersistenceTests: XCTestCase {
    struct Record: Codable, Equatable { let text: String }
    typealias Store = HistoryPersistence<Record>

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLegacyFilesLoadWithoutMigration() throws {
        let dir = try directory()
        let records = [Record(text: "existing")]
        let deleted = [UUID().uuidString: Date(timeIntervalSince1970: 20)]
        try JSONEncoder().encode(records).write(to: dir.appendingPathComponent("history.json"))
        try JSONEncoder().encode(deleted).write(to: dir.appendingPathComponent("history-deletions.json"))
        let state = try Store(directory: dir).load()
        XCTAssertEqual(state.records, records)
        XCTAssertEqual(state.deletions, deleted)
    }

    func testFailuresAtEveryCommitStepRecoverOneWholeSnapshot() throws {
        for failureAt in 1...4 {
            let dir = try directory()
            let clean = Store(directory: dir)
            let old = Store.State(records: [.init(text: "old")], deletions: [:])
            let new = Store.State(records: [.init(text: "new")], deletions: [UUID().uuidString: Date()])
            try clean.save(old)
            var step = 0
            let failing = Store(directory: dir, write: { data, url in
                step += 1
                if step == failureAt { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }, remove: { url in
                step += 1
                if step == failureAt { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
            XCTAssertThrowsError(try failing.save(new))
            let recovered = try clean.load()
            let expected = failureAt == 1 ? old : new
            XCTAssertEqual(recovered.records, expected.records, "step \(failureAt)")
            XCTAssertEqual(recovered.deletions, expected.deletions, "step \(failureAt)")
            try clean.save(new)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history-transaction.json").path))
            XCTAssertEqual(try clean.load().records, new.records)
            XCTAssertEqual(try clean.load().deletions, new.deletions)
        }
    }

    func testCorruptJournalIsPreservedAndDoesNotFallBackToMixedFiles() throws {
        let dir = try directory()
        let store = Store(directory: dir)
        try store.save(.init(records: [.init(text: "old")], deletions: [:]))
        let url = dir.appendingPathComponent("history-transaction.json")
        let corrupt = Data("broken transaction".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnreadableFileDoesNotMasqueradeAsEmptyHistory() throws {
        let store = Store(directory: try directory(), read: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertThrowsError(try store.load())
    }

    func testCommitKeepsBothLegacyFileFormatsReadable() throws {
        let dir = try directory()
        let state = Store.State(records: [.init(text: "中文 👩🏽‍💻")], deletions: [UUID().uuidString: Date()])
        try Store(directory: dir).save(state)
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: Data(contentsOf: dir.appendingPathComponent("history.json"))), state.records)
        XCTAssertEqual(try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: dir.appendingPathComponent("history-deletions.json"))), state.deletions)
    }
}
