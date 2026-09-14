import Foundation

/// 轻量共享诊断日志:键盘扩展与主 App 各写各的文件(免跨进程锁),读取时按时间戳前缀合并排序。
/// 用途:真机排障——用户复现故障后在 App 内"诊断日志"页一键复制发回。
/// 原则:丢一两行可接受;绝不能崩溃或阻塞键盘 —— 写入全走后台串行队列,一切失败静默。
/// 只记语音桥/录音相关事件,不记打字/候选(键盘扩展 CPU/内存预算)。
/// 例外:[KB][perf] 拼音候选耗时诊断——仅当单次耗时超过一帧(~16ms)才写一行,
/// 用于真机场景下定位敲键卡顿,不逐键无条件记录,开销可忽略。
enum DiagLog {
    private static let queue = DispatchQueue(label: "org.example.voicepen.diaglog", qos: .utility)
    private static let maxBytes: UInt64 = 512 * 1024   // 单进程文件 ~500KB 触发压缩
    private static let keepBytes = 128 * 1024          // 压缩后保留尾部字节数(按行对齐)
    /// 进程标签:键盘扩展(bundle 以 .appex 结尾)= KB,主 App = APP
    private static let processTag = Bundle.main.bundlePath.hasSuffix(".appex") ? "KB" : "APP"

    /// 固定格式 + POSIX locale:行首时间戳字典序即时间序,合并时直接 sort
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// App Group 容器优先(两进程共享);不可用时静默降级为本进程 Caches(至少主 App 侧可见)
    private static let directory: URL? = {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent("Diag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var fileURL: URL? {
        directory?.appendingPathComponent("diag-\(processTag).log")
    }

    /// 追加一行:时间戳(毫秒) [进程][组件] 消息。异步、静默,可在任意线程调用。
    static func log(_ component: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(processTag)][\(component)] \(message)\n"
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url)   // 文件不存在:首次创建
                return
            }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            if end > maxBytes { compact(url) }
        }
    }

    /// 超限压缩:只保留尾部 keepBytes,并对齐到下一个整行开头。
    private static func compact(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        var tail = data.suffix(keepBytes)
        if let nl = tail.firstIndex(of: 0x0a) { tail = tail.suffix(from: tail.index(after: nl)) }
        try? tail.write(to: url, options: .atomic)
    }

    /// 合并 APP/KB 两个文件,按时间戳行前缀排序,返回最近 limit 行(旧→新)。
    static func readMerged(limit: Int = 3000) -> [String] {
        guard let dir = directory else { return [] }
        var lines: [String] = []
        for tag in ["APP", "KB"] {
            let url = dir.appendingPathComponent("diag-\(tag).log")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            }
        }
        lines.sort()
        return Array(lines.suffix(limit))
    }

    /// 一次性自检:把"日志到底写没写进去、没写进去是因为什么"落到 App Group 的
    /// `diagLogSelfCheck` 键里(该通道可用 devicectl 远程读取)。
    ///
    /// 起因:2026-08-04 排查待命问题时发现 `Diag/*.log` 在 App Group 容器和 App 自身容器里
    /// 都不存在,而全文件的写入路径都用 `try?` 吞掉了错误,现场没有任何线索。这里刻意用
    /// `do/catch` 取回真实 error,只在启动时跑一次,开销可忽略。
    static func recordSelfCheck() {
        queue.async {
            var parts: [String] = []
            let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            parts.append("tag=\(processTag)")
            parts.append("groupContainer=\(groupURL?.path ?? "nil")")
            parts.append("freeAccountBuild=\(AppGroup.freeAccountBuild)")

            guard let dir = directory else {
                parts.append("directory=nil")
                AppGroup.suite?.set(parts.joined(separator: " "), forKey: "diagLogSelfCheck")
                return
            }
            parts.append("dir=\(dir.path)")
            parts.append("dirExists=\(FileManager.default.fileExists(atPath: dir.path))")

            // 目录创建的真实结果(原实现是 try?,失败无声)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                parts.append("mkdir=ok")
            } catch {
                parts.append("mkdir=ERR(\((error as NSError).domain)/\((error as NSError).code))")
            }

            // 写入的真实结果
            if let url = fileURL {
                let existed = FileManager.default.fileExists(atPath: url.path)
                parts.append("fileExisted=\(existed)")
                do {
                    let probe = "\(formatter.string(from: Date())) [\(processTag)][selfcheck] probe\n"
                    if existed, let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        _ = try handle.seekToEnd()
                        try handle.write(contentsOf: Data(probe.utf8))
                        parts.append("append=ok")
                    } else {
                        try Data(probe.utf8).write(to: url)
                        parts.append("create=ok")
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
                    parts.append("size=\(size.map(String.init) ?? "?")")
                } catch {
                    let ns = error as NSError
                    parts.append("write=ERR(\(ns.domain)/\(ns.code):\(ns.localizedDescription))")
                }
            }
            AppGroup.suite?.set(parts.joined(separator: " "), forKey: "diagLogSelfCheck")
        }
    }

    /// 把合并后的日志镜像一份到 **App 自身容器**,供 `devicectl` 远程拉取。
    ///
    /// 起因(2026-08-04 查实):`devicectl device copy from` 对 App Group 容器只接受
    /// `--source /`(子路径一律报假错 "File paths cannot contain '..'"),而拷 `/` 时又会
    /// 静默跳过 `Diag/` 只返回 `Library/`;同一命令对 App 自身容器则递归正常。
    /// 日志本体仍写在 App Group(键盘扩展要能写),这里只是多留一份可远程取回的副本。
    ///
    /// 拉取:
    /// ```
    /// xcrun devicectl device copy from --device <UDID> \
    ///   --domain-type appDataContainer --domain-identifier org.example.VoicePenMobile \
    ///   --source / --destination <dir>
    /// # 副本在 <dir>/Library/Application Support/DiagMirror/diag-merged.log
    /// ```
    static func mirrorToAppContainer() {
        queue.async {
            let merged = readMerged()
            guard !merged.isEmpty,
                  let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask).first
            else { return }
            let dir = support.appendingPathComponent("DiagMirror", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = merged.joined(separator: "\n") + "\n"
            try? Data(text.utf8).write(
                to: dir.appendingPathComponent("diag-merged.log"), options: .atomic)
        }
    }

    static func clear() {
        guard let dir = directory else { return }
        for tag in ["APP", "KB"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("diag-\(tag).log"))
        }
    }
}
