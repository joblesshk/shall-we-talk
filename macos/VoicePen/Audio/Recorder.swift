import AVFoundation

/// AVAudioEngine 录音,重采样为 16kHz 单声道 Int16,stop() 返回完整 WAV 数据
final class Recorder {
    // Do not retain the previous day's hardware graph across recordings.
    // start/stop are called serially by AppState on the main actor.
    private var engine: AVAudioEngine?
    private var pcm = Data()
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    /// 与 iOS 一致的采样闸门。AVAudioEngine 的 tap 运行在实时音频线程，stop() 运行
    /// 在主线程；必须先在同一把锁下关闭闸门，才能保证已经在转换中的迟到缓冲不会在
    /// 流式会话发出结束帧之后继续进入 PCM/WAV 或 `onChunk`。
    private var capturing = false
    private var captureGeneration: UInt64 = 0
    private var chunkHandler: ((Data) -> Void)?
    private var levelHandler: ((Float) -> Void)?

    /// 实时块回调(16k mono Int16),供流式识别边录边传;在音频线程调用
    var onChunk: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return chunkHandler }
        set { lock.lock(); defer { lock.unlock() }; chunkHandler = newValue }
    }
    /// 实时音量回调(0...1,由 RMS 换算),驱动浮窗波形;在音频线程调用
    var onLevel: ((Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return levelHandler }
        set { lock.lock(); defer { lock.unlock() }; levelHandler = newValue }
    }

    func start() throws {
        guard engine == nil else {
            throw NSError(domain: "Recorder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "录音已在进行中"])
        }
        // 先重置本次采样状态；capturing 直到 tap 安装完成前才打开，避免旧会话的迟到
        // 回调污染下一次口述。
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        converter = nil
        capturing = false
        captureGeneration &+= 1
        let generation = captureGeneration
        lock.unlock()

        let newEngine = AVAudioEngine()
        lock.lock()
        // 在 engine.start() 前打开闸门，避免漏掉引擎启动后立即到达的首块缓冲。
        capturing = true
        lock.unlock()
        let error = SWTStartAudioEngine(newEngine) { [weak self] buffer, _ in
            self?.append(buffer, generation: generation)
        }
        if let error {
            lock.lock()
            capturing = false
            converter = nil
            lock.unlock()
            throw error
        }
        engine = newEngine
    }

    private func append(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0,
              buffer.frameLength > 0 else { return }
        lock.lock()
        let shouldCapture = capturing && captureGeneration == generation
        // Hardware may switch sample rate/channels (e.g. Bluetooth hands-free).
        // Convert from the actual tap buffer rather than a pre-start snapshot.
        if shouldCapture, converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        let activeConverter = converter
        lock.unlock()
        guard shouldCapture, let activeConverter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var served = false
        activeConverter.convert(to: out, error: nil) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        // 转码期间可能刚好点击了停止。iOS 与 Mac 都以这一步为最终裁决点：迟到的音频
        // 不得进入本地 WAV，也不得继续投递给已经收尾的 WebSocket 会话。
        let stillCapturing = capturing && captureGeneration == generation
        if stillCapturing { pcm.append(data) }
        let deliverChunk = stillCapturing ? chunkHandler : nil
        let deliverLevel = stillCapturing ? levelHandler : nil
        lock.unlock()
        guard stillCapturing else { return }
        // Invoke snapshots outside the lock: callbacks may change recorder state.
        // A callback already in flight belongs to its old session, never the next.
        deliverChunk?(data)

        // RMS → dB → 0...1:-50dB 视为静音,-10dB 拉满,正常说话变化明显
        if let onLevel = deliverLevel {
            let n = Int(out.frameLength)
            var sum: Float = 0
            for i in 0..<n {
                let s = Float(ch[0][i]) / 32768
                sum += s * s
            }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 0.00001))
            onLevel(max(0, min(1, (db + 50) / 40)))
        }
    }

    func stop() -> Data {
        // 必须在 removeTap/engine.stop 之前关门并取得同一时点的 PCM 快照。这样即使音频
        // 线程已经进入 append()，它也会在 `stillCapturing` 处被拦下，不能晚于 ASR 结束帧。
        lock.lock()
        capturing = false
        let body = pcm
        lock.unlock()
        if let engine { SWTStopAudioEngine(engine) }
        engine = nil
        lock.lock()
        converter = nil
        lock.unlock()
        return Self.wav(pcm: body, sampleRate: 16000, channels: 1)
    }

    static func wav(pcm: Data, sampleRate: Int, channels: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * channels * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1) // PCM
        u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(channels * 2)); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
