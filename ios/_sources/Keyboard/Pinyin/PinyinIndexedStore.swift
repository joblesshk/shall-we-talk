import Foundation
import SQLite3

/// Build-time indexes over the annotated rime-ice dictionary. The connection is opened
/// in the loader, then handed to the main thread with its owning PinyinDictionary.
/// No concurrent access; immutable built-in data, user words stay in the separate overlay.
final class PinyinIndexedStore {
    struct Row {
        let entry: PinyinEntry
        let pinyin: String
    }
    enum Index: String { case pinyin, t9, initials }
    private var databases: [Index: OpaquePointer] = [:]
    private var statements: [String: OpaquePointer] = [:]
    private var cache: [String: [Row]] = [:]
    private var cacheOrder: [String] = []
    private(set) var entryCount = 0

    init?(url: URL) {
        for index in [Index.pinyin, .t9, .initials] {
            let actual = index == .pinyin ? url : url.deletingLastPathComponent()
                .appendingPathComponent("pinyin_ice_\(index.rawValue).sqlite")
            var db: OpaquePointer?
            guard sqlite3_open_v2(actual.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let db else {
                if let db { sqlite3_close(db) }; return nil
            }
            databases[index] = db
            // Three stores map at most 4 MiB each, plus 256 KiB page cache each.
            // Keep resident pages bounded as well as private heap use.
            sqlite3_exec(db, "PRAGMA cache_size=-256; PRAGMA mmap_size=4194304; PRAGMA query_only=ON;", nil, nil, nil)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key='entries' AND (SELECT user_version FROM pragma_user_version)=2", -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement); return nil
            }
            let count = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
            sqlite3_finalize(statement)
            guard count > 0 else { return nil }
            if index == .pinyin { entryCount = count }
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        for db in databases.values { sqlite3_close(db) }
    }

    /// Broad prefix ranges are pre-ranked at build time; other prefix ranges have at
    /// most 128 rows to sort. Exact queries read the covering primary key directly.
    /// Result caches and SQLite page caches are bounded independently of total entries.
    func lookup(_ key: String, index: Index, prefix: Bool = false,
                excludingExact: Bool = true, charsOnly: Bool = false, limit: Int, precomputed: Bool = true) -> [Row] {
        guard !key.isEmpty, limit > 0 else { return [] }
        let limit = min(limit, 512)
        if prefix && !excludingExact {
            // Merge two bounded ranked sets; never sort a whole single-digit range.
            let exact = lookup(key, index: index, charsOnly: charsOnly, limit: limit)
            let longer = lookup(key, index: index, prefix: true, limit: limit)
            return Array((exact + longer).sorted {
                if $0.entry.freq != $1.entry.freq { return $0.entry.freq > $1.entry.freq }
                if $0.entry.syllableCount != $1.entry.syllableCount { return $0.entry.syllableCount > $1.entry.syllableCount }
                return $0.entry.word < $1.entry.word
            }.prefix(limit))
        }
        let cacheKey = "\(index.rawValue)|\(key)|\(prefix)|\(excludingExact)|\(charsOnly)|\(limit)"
        if let hit = cache[cacheKey] { return hit }
        let column = "code" // fixed schema column, never user-provided SQL
        let materialized = prefix && excludingExact && precomputed && index != .initials
        let sql: String
        if materialized {
            sql = "SELECT word,syllables,freq,pinyin FROM completions WHERE prefix=?1 ORDER BY rank LIMIT ?3"
        } else {
            let predicate = prefix ? "\(column) \(excludingExact ? ">" : ">=") ?1 AND \(column) < ?2" : "\(column)=?1"
            sql = "SELECT word,syllables,freq,pinyin FROM lexicon WHERE \(predicate)\(charsOnly ? " AND syllables=1" : "") ORDER BY freq DESC,syllables DESC,word,pinyin LIMIT ?3"
        }
        let statementKey = index.rawValue + sql
        let statement: OpaquePointer
        if let prepared = statements[statementKey] { statement = prepared }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(databases[index], sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { return [] }
            statement = prepared; statements[statementKey] = statement
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ text: String, _ position: Int32) {
            _ = text.withCString { sqlite3_bind_text(statement, position, $0, -1, transient) }
        }
        if materialized { bind(key, 1) }
        else { bind(key, 1); if prefix { bind(key + "{", 2) } }
        sqlite3_bind_int(statement, 3, Int32(limit))
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let word = sqlite3_column_text(statement, 0), let pinyin = sqlite3_column_text(statement, 3) else { continue }
            rows.append(Row(entry: PinyinEntry(word: String(cString: word),
                syllableCount: Int(sqlite3_column_int(statement, 1)),
                freq: Int(sqlite3_column_int64(statement, 2))), pinyin: String(cString: pinyin)))
        }
        if materialized && rows.isEmpty {
            return lookup(key, index: index, prefix: prefix, excludingExact: excludingExact,
                          charsOnly: charsOnly, limit: limit, precomputed: false)
        }
        if cacheOrder.count >= 128 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheOrder.append(cacheKey); cache[cacheKey] = rows
        return rows
    }
}
