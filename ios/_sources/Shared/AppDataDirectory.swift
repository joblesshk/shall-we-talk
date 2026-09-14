import Foundation

/// 用户可见品牌改名后的本地数据目录。
/// 技术身份(Bundle ID / App Group)保持不变，但 Application Support 目录
/// 从旧品牌 Show We Talk 一次性迁移到 Shall We Talk。
enum AppDataDirectory {
    static func url() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = root.appendingPathComponent("Shall We Talk", isDirectory: true)
        let legacy = root.appendingPathComponent("Show We Talk", isDirectory: true)
        migrateDirectoryIfNeeded(from: legacy, to: current)
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    private static func migrateDirectoryIfNeeded(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
            DiagLog.log("migration", "已迁移本地数据目录 Show We Talk → Shall We Talk")
        } catch {
            // 迁移失败时宁可继续读旧目录，绝不让历史/待办表现为丢失。
            DiagLog.log("migration", "品牌目录迁移失败,继续使用旧目录: \(error.localizedDescription)")
        }
    }
}
