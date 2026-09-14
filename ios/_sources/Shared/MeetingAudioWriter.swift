import Foundation

/// 边录边落盘的 WAV 写入器,一个 segment 一个实例。
///
/// 为什么需要它:`Recorder` 把整段录音攒在内存 `Data` 里,`stop()` 才整体返回——这对
/// 几十秒的口述没问题,但一场两小时会议是约 230MB 常驻内存(16kHz 单声道 16bit ≈
/// 32KB/s),App 会在会议结束前就被系统按内存杀掉。`MeetingAudioWriter` 把这份职责
/// 挪到磁盘:开一个文件句柄,边收到 PCM 块边写,只在内存里留一个写队列的瞬时缓冲。
///
/// 线程约定:`append(_:)` 从 `Recorder.onChunk` 回调,而那个回调运行在音频采集的
/// 实时线程上——绝不能在那里做同步文件 I/O(会话丢帧/卡顿)。这里把每次 append
/// 派发到一个私有串行队列,真正的 write(contentsOf:) 发生在那个队列上,音频线程
/// 只负责把 Data 丢进队列就立刻返回。
final class MeetingAudioWriter {
    /// 完整 WAV 合并与整场删除必须串行：否则删除时正在运行的合并任务
    /// 可能在删除返回后又生成 `-complete.wav`。
    private static let archiveIOQueue = DispatchQueue(label: "meeting.audio.archive", qos: .utility)

    private let url: URL
    private let queue = DispatchQueue(label: "meeting.audio.write", qos: .utility)
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private var openError: Error?

    /// 写 44 字节占位 RIFF/WAVE 头(大小字段先填 0,`close()` 时回填真实字节数)。
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        handle.write(Self.placeholderHeader())
        self.handle = handle
    }

    /// 供 `Recorder.onChunk` 直接挂载。非阻塞:立即返回,真正的写入发生在后台队列。
    func append(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            do {
                try handle.write(contentsOf: pcm)
                self.bytesWritten += UInt64(pcm.count)
            } catch {
                self.openError = error
                DiagLog.log("meetingAudio", "写入失败 file=\(self.url.lastPathComponent) error=\(error.localizedDescription)")
            }
        }
    }

    /// 冲刷队列、回填 RIFF/data 大小字段、关闭文件句柄。同步等待队列排空,
    /// 调用方(段落收尾流程)本就在等这个文件就绪才能进入下一步(存档/上传),
    /// 不引入额外的异步包装。
    @discardableResult
    func close() -> URL? {
        queue.sync { }
        guard let handle else { return nil }
        do {
            try handle.close()
        } catch {
            DiagLog.log("meetingAudio", "关闭句柄失败 file=\(url.lastPathComponent) error=\(error.localizedDescription)")
        }
        self.handle = nil
        Self.repairHeader(at: url)
        if let openError {
            DiagLog.log("meetingAudio", "段落写入曾出错,文件可能不完整: \(openError.localizedDescription)")
            // 保留文件供诊断/人工恢复，但绝不能把它当作完整段落写回 store。
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var currentByteCount: UInt64 {
        queue.sync { bytesWritten }
    }

    /// 按磁盘上的真实文件大小重算并回填 RIFF/data 大小字段。用于:
    /// ① 正常 `close()` 收尾;② 崩溃/被杀后由 `MeetingStore` 在下次启动时对着
    /// 遗留的占位头文件补一次,让部分录音仍然可播放,而不是一个头部字节数为 0
    /// 播放器打不开的"坏文件"。
    static func repairHeader(at url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64, fileSize >= 44 else { return }
        let pcmBytes = fileSize - 44
        defer { try? handle.close() }
        handle.seek(toFileOffset: 4)
        handle.write(Self.u32LE(UInt32(truncatingIfNeeded: 36 + pcmBytes)))
        handle.seek(toFileOffset: 40)
        handle.write(Self.u32LE(UInt32(truncatingIfNeeded: pcmBytes)))
    }

    /// 将会议技术分段合成为一份可独立保存的 WAV。只复制每段的 PCM 数据，不把多个
    /// RIFF 头拼在一起；因此即便因为蓝牙切换、来电或 20 分钟轮转产生多段，用户仍能
    /// 导出一份完整录音。合成始终先写临时文件，再替换旧的合成副本；任一步失败都不会
    /// 删除任一原始分段文件。
    static func combineWAVSegments(_ sourceURLs: [URL], to destination: URL) throws {
        try archiveIOQueue.sync {
            try combineWAVSegmentsUncoordinated(sourceURLs, to: destination)
        }
    }

    /// 删除某场会议的所有音频：已登记的历史文件名，以及按会议 UUID
    /// 命名的分段、完整 WAV 和崩溃/合并遗留的隐藏临时文件。
    static func removeMeetingAudio(meetingID: UUID, referencedFileNames: [String], in directory: URL) throws {
        try archiveIOQueue.sync {
            let fm = FileManager.default
            let prefix = meetingID.uuidString.lowercased() + "-"
            var files = Set(referencedFileNames.map { directory.appendingPathComponent(($0 as NSString).lastPathComponent) })
            let stored = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in stored {
                let name = url.lastPathComponent.lowercased()
                if name.hasPrefix(prefix) || name.hasPrefix("." + prefix) { files.insert(url) }
            }
            var firstError: Error?
            for url in files where fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    private static func combineWAVSegmentsUncoordinated(_ sourceURLs: [URL], to destination: URL) throws {
        guard !sourceURLs.isEmpty else {
            throw NSError(domain: "MeetingAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可合并的录音片段"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        fm.createFile(atPath: temporary.path, contents: Self.placeholderHeader())
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        var pcmByteCount: UInt64 = 0
        for source in sourceURLs {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let header = try input.read(upToCount: 44) ?? Data()
            guard header.count == 44,
                  header.prefix(4) == Data("RIFF".utf8),
                  header.subdata(in: 8..<12) == Data("WAVE".utf8) else {
                throw NSError(domain: "MeetingAudio", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "录音片段格式无效：\(source.lastPathComponent)"])
            }
            while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
                try output.write(contentsOf: block)
                pcmByteCount += UInt64(block.count)
            }
        }
        try output.synchronize()
        try output.close()
        Self.repairHeader(at: temporary)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary,
                                     backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        DiagLog.log("meetingAudio", "完整录音已合并 file=\(destination.lastPathComponent) pcm=\(pcmByteCount)B")
    }

    // MARK: - WAV 头(16kHz/mono/16bit,与 `Recorder.wav(pcm:sampleRate:channels:)` 同规格)

    private static func placeholderHeader() -> Data {
        header(pcmByteCount: 0)
    }

    private static func header(pcmByteCount: UInt32) -> Data {
        var d = Data()
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * 2
        d.append("RIFF".data(using: .ascii)!); d.append(u32LE(36 + pcmByteCount))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); d.append(u32LE(16)); d.append(u16LE(1))
        d.append(u16LE(channels)); d.append(u32LE(sampleRate)); d.append(u32LE(byteRate))
        d.append(u16LE(channels * 2)); d.append(u16LE(16))
        d.append("data".data(using: .ascii)!); d.append(u32LE(pcmByteCount))
        return d
    }

    private static func u32LE(_ v: UInt32) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func u16LE(_ v: UInt16) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 2)
    }
}
