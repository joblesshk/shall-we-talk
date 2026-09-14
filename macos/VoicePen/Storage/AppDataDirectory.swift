import Foundation

/// macOS 品牌从 VoicePen 统一为 Shall We Talk 时保留原有历史、待办和测试配置。
enum AppDataDirectory {
    static func url() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = root.appendingPathComponent("Shall We Talk", isDirectory: true)
        let legacy = root.appendingPathComponent("VoicePen", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.moveItem(at: legacy, to: current)
            } catch {
                // 迁移失败时仍使用旧目录，避免历史和待办在界面上“消失”。
                return legacy
            }
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }
}
