import AVFoundation

/// AVAudioEngine 录音,重采样为 16kHz 单声道 Int16,stop() 返回完整 WAV 数据
final class Recorder {
    // 冷启动必须在 AVAudioSession 激活后重建引擎。若长期复用一个在旧路由/未激活会话下
    // 创建过 inputNode 的 engine，reset() 只清图，不会重建底层 Audio Unit，真机会持续 -10868。
    private var engine = AVAudioEngine()
    private var pcm = Data()
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    /// 热会话标记:键盘接力模式 stop(keepHot:) 后保持引擎+音频会话存活,后续"开始"只是恢复取样。
    private var hotFlag = false
    /// 采样闸门:false 时 tap 回调直接丢弃缓冲(热会话空闲期不积累内存)。
    // AVAudioEngine 的 tap 在实时音频线程调用,而 start/stop 在主线程调用。
    // 该状态必须与 pcm/converter 一起受锁保护;否则热会话加入后会形成数据竞争,
    // 音频线程可能持续读到旧的 false,界面虽显示录音却把所有输入块丢掉。
    private var capturing = false
    private var capturedBytes = 0

    /// 热会话是否真实存活(引擎仍在跑;来电/Siri 中断会让引擎停转,此时自动视为冷)。
    var isHot: Bool { hotFlag && engine.isRunning }

    /// 输入引擎此刻是否真的在跑,**不看 hotFlag**。
    ///
    /// `isHot` 要求 `hotFlag`,而 `hotFlag` 只由 `warmUp()` 和 `stop(keepHot: true)` 置位;
    /// 一段正在进行的冷起录音里它仍是 false。纯音频待命(`AudioSessionStandbyController`)
    /// 要的是"这条音频会话还活着没有",键盘冷启动时待命恰好是在录音**中途**建立的,
    /// 用 `isHot` 判定会误报未启动。中断让引擎停转时这里同样立刻变 false ——
    /// 这正是 §13.2「进程存在≠后台可用」要求的独立存活判据。
    var isEngineLive: Bool { engine.isRunning }

    /// 是否在中断前被要求保持热会话。这与 `isHot` 必须分开:
    /// iOS 会先停掉 AVAudioEngine，再投递 interruption began；因此通知到达时
    /// `isHot` 已经是 false，但 hotFlag 仍然记录着这是一条应当恢复的待命会话。
    var hasHotSessionIntent: Bool { hotFlag }

    /// 本次起录以来真正收到并转码的字节数。用于判定"引擎起来了但系统一个样本都不给":
    /// 后台开麦被 iOS 静默拒绝时 start() 不抛错、engine.isRunning 也为真,只是 tap 永远不回调
    /// (2026-08-06 真机日志实证:后台那次没有"首块缓冲建立转换器",随后进程被回收,录音是黑洞)。
    var capturedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return capturedBytes
    }

    /// 实时块回调(16k mono Int16),供流式识别边录边传;在音频线程调用
    var onChunk: ((Data) -> Void)?
    /// 实时音量回调(0...1,由 RMS 换算),驱动浮窗波形;在音频线程调用
    var onLevel: ((Float) -> Void)?

    /// 会议模式关掉:整段会议由 MeetingAudioWriter 边录边落盘,pcm 不再驻留内存
    /// (两小时会议在内存里攒完整 WAV 会把 App 拖进 jetsam)。onChunk/onLevel/capturedBytes
    /// 行为不变;关闭时 stop() 返回空 WAV,调用方不得使用其返回值。teardown() 里复位为 true,
    /// 防止会议残留的 false 悄悄影响之后的口述。
    var retainsPCM = true

    /// 从前台显式开启免切换待命：启动真实输入引擎后立即关闭采样闸门。
    /// 空闲期缓冲会在 tap 中直接丢弃，不写文件、不触发 ASR/LLM，也不上传。
    func warmUp() throws {
        if isHot { return }
        try start()
        lock.lock()
        capturing = false
        pcm.removeAll(keepingCapacity: true)
        capturedBytes = 0
        hotFlag = engine.isRunning
        lock.unlock()
        DiagLog.log("recorder", "前台预热完成，关闭采样闸门并保持音频会话")
    }

    func start() throws {
        // 热会话直通:引擎/音频会话都还活着,只清缓冲、打开采样闸门——不重新 setActive,
        // 这正是后台合法"续录"的关键(iOS 禁止后台重新激活录音会话,'!rec')。
        if isHot {
            DiagLog.log("recorder", "热直通:引擎/会话存活,直接恢复取样")
            lock.lock()
            pcm.removeAll(keepingCapacity: true)
            capturedBytes = 0
            capturing = true
            lock.unlock()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        capturedBytes = 0
        capturing = false
        lock.unlock()
        #if os(iOS)
        // 默认使用 iOS 原生 Voice Processing + AGC。部分蓝牙路由、后台恢复窗口或设备状态
        // 可能无法建立 Voice I/O；同一次启动内自动退回原来的 .record/.measurement 路径，
        // 不做额外数字放大，也不让系统增强能力影响录音可用性。
        do {
            try startIOSCapture(useSystemVoiceProcessing: true)
        } catch {
            let enhancedError = error as NSError
            DiagLog.log("recorder", "系统人声增强不可用，自动回退原声兼容模式: \(enhancedError.domain) \(enhancedError.code) \(enhancedError.localizedDescription)")
            cleanupFailedStart()
            do {
                try startIOSCapture(useSystemVoiceProcessing: false)
                DiagLog.log("recorder", "原声兼容模式起录成功")
            } catch {
                let fallbackError = error as NSError
                DiagLog.log("recorder", "原声兼容模式仍启动失败: \(fallbackError.domain) \(fallbackError.code) \(fallbackError.localizedDescription)")
                throw error
            }
        }
        return
        #endif

        #if !os(iOS)
        let input = engine.inputNode
        let reportedInputFormat = input.outputFormat(forBus: 0)
        guard isUsableInputFormat(reportedInputFormat) else {
            throw NSError(domain: "Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的输入设备"])
        }
        let tapFormat: AVAudioFormat? = reportedInputFormat
        try beginCapture(input: input, reportedInputFormat: reportedInputFormat, tapFormat: tapFormat)
        #endif
    }

    private func beginCapture(input: AVAudioInputNode,
                              reportedInputFormat: AVAudioFormat?,
                              tapFormat: AVAudioFormat?) throws {
        lock.lock()
        #if os(iOS)
        converter = nil
        #else
        if let reportedInputFormat {
            converter = AVAudioConverter(from: reportedInputFormat, to: target)
        }
        #endif
        // 在 engine.start() 之前打开闸门,避免丢掉引擎启动后立即送来的首批缓冲。
        capturing = true
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch let error as NSError {
            lock.lock(); capturing = false; lock.unlock()
            #if os(iOS)
            let route = audioRouteDiagnostics(
                session: AVAudioSession.sharedInstance(),
                format: input.inputFormat(forBus: 0)
            )
            throw NSError(
                domain: "Recorder.EngineStart",
                code: error.code,
                userInfo: [NSLocalizedDescriptionKey: "音频引擎启动失败; \(route); underlying=\(error.domain) \(error.code)"]
            )
            #else
            throw error
            #endif
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let shouldCapture = capturing
        if converter == nil, isUsableInputFormat(buffer.format) {
            converter = AVAudioConverter(from: buffer.format, to: target)
            if converter != nil {
                DiagLog.log("recorder", "首块缓冲建立转换器 rate=\(Int(buffer.format.sampleRate)) channels=\(buffer.format.channelCount)")
            }
        }
        let activeConverter = converter
        lock.unlock()
        guard shouldCapture, let activeConverter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var served = false
        var conversionError: NSError?
        activeConverter.convert(to: out, error: &conversionError) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            DiagLog.log("recorder", "音频转换失败: \(conversionError.domain) \(conversionError.code) \(conversionError.localizedDescription)")
            return
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        // stop() 可能在转换过程中关闭闸门;关闭后不再把迟到块混入本次结果。
        let stillCapturing = capturing
        if stillCapturing {
            if retainsPCM { pcm.append(data) }
            capturedBytes += data.count
        }
        lock.unlock()
        guard stillCapturing else { return }
        onChunk?(data) // 本地始终全量落盘,流式只是并行加速

        // RMS → dB → 0...1:-50dB 视为静音,-10dB 拉满,正常说话变化明显
        if let onLevel {
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

    /// keepHot=true(键盘接力):只关采样闸门,引擎与音频会话保持存活,后续 start() 走热直通;
    /// keepHot=false(默认,App 内/中断):完整停机 + 退出音频会话,与原行为一致。
    func stop(keepHot: Bool = false, preserveAudioSession: Bool = false) -> Data {
        lock.lock()
        capturing = false
        let body = pcm
        let byteCount = capturedBytes
        lock.unlock()
        let duration = String(format: "%.2f", Double(byteCount) / 32000)
        DiagLog.log("recorder", "取样结束 pcm=\(byteCount)B 时长约=\(duration)s")
        if keepHot, engine.isRunning {
            hotFlag = true
            DiagLog.log("recorder", "停止取样并保持热会话(引擎继续空转)")
            return Self.wav(pcm: body, sampleRate: 16000, channels: 1)
        }
        teardown(deactivateAudioSession: !preserveAudioSession)
        return Self.wav(pcm: body, sampleRate: 16000, channels: 1)
    }

    /// 完整停机到冷状态:拆 tap、停引擎、退音频会话。热会话空闲超时/中断时由外部调用。
    func teardown(deactivateAudioSession: Bool = true) {
        DiagLog.log("recorder", "完整停机(拆 tap/停引擎/退会话)wasHot=\(hotFlag)")
        hotFlag = false
        lock.lock(); capturing = false; lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        lock.lock(); converter = nil; lock.unlock()
        #if os(iOS)
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    #if os(iOS)
    private func startIOSCapture(useSystemVoiceProcessing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try configureAudioSession(session, useSystemVoiceProcessing: useSystemVoiceProcessing)
        DiagLog.log("recorder", "音频会话已激活 route=\(session.currentRoute.inputs.first?.portType.rawValue ?? "无输入") profile=\(useSystemVoiceProcessing ? "voiceProcessing+AGC" : "measurement")")

        // 会话激活、输入路由确定之后重建引擎，避免复用旧 Audio Unit 导致 -10868。
        engine = AVAudioEngine()
        let input = engine.inputNode
        if useSystemVoiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            guard input.isVoiceProcessingEnabled, input.isVoiceProcessingAGCEnabled else {
                throw NSError(domain: "Recorder.VoiceProcessing", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "iOS 未能启用人声处理或自动增益"])
            }
            DiagLog.log("recorder", "iOS 原生人声处理已启用 voiceProcessing=true agc=true")
        }

        let reportedInputFormat = resolveInputFormat(from: input, session: session,
                                                     useSystemVoiceProcessing: useSystemVoiceProcessing)
        // tap 传 nil，让 Voice I/O 或硬件 Audio Unit 决定原生格式；首块再转为 ASR 所需 16k。
        let tapFormat: AVAudioFormat? = nil
        DiagLog.log("recorder", "tap改用系统协商格式; reportedRate=\(Int(reportedInputFormat?.sampleRate ?? 0)) channels=\(reportedInputFormat?.channelCount ?? 0)")
        try beginCapture(input: input, reportedInputFormat: reportedInputFormat, tapFormat: tapFormat)
    }

    private func configureAudioSession(_ session: AVAudioSession,
                                       useSystemVoiceProcessing: Bool) throws {
        if useSystemVoiceProcessing {
            // Voice Processing 需要 Voice I/O 的输入与输出节点，因此采用 playAndRecord + voiceChat。
            // 实际输出为空；这里只借助系统提供的语音优化、降噪与 AGC，不叠加软件增益。
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.allowBluetoothHFP])
        } else {
            // 兼容路径保留已在真机验证过的无输出测量模式。
            try session.setCategory(.record,
                                    mode: .measurement,
                                    options: [.allowBluetoothHFP])
        }
        // 不要求硬件直接输出 16kHz；不同麦克风/蓝牙路由支持的原生采样率不同。
        // append(_:) 中的 AVAudioConverter 负责统一转成 ASR 所需的 16kHz。
        try? session.setPreferredIOBufferDuration(0.02)
        // 先选输入、再激活;旧顺序在 setActive 后才 setPreferredInput,
        // 会让已激活的路由立即再配置,此时 inputNode 常短暂报 0Hz。
        if let input = preferredInput(for: session) {
            try? session.setPreferredInput(input)
        }
        try session.setActive(true)
    }

    private func cleanupFailedStart() {
        lock.lock(); capturing = false; converter = nil; lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func preferredInput(for session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let availableInputs = session.availableInputs ?? []
        if let current = session.currentRoute.inputs.first,
           let match = availableInputs.first(where: { $0.uid == current.uid }) {
            return match
        }
        return availableInputs.first(where: { $0.portType == .builtInMic }) ?? availableInputs.first
    }

    private func resolveInputFormat(from input: AVAudioInputNode,
                                    session: AVAudioSession,
                                    useSystemVoiceProcessing: Bool) -> AVAudioFormat? {
        // Apple 对 AVAudioEngine.inputNode 的建议是检查 inputFormat（硬件格式）是否可用。
        var format = input.inputFormat(forBus: 0)
        for attempt in 0..<6 {
            if isUsableInputFormat(format) { return format }
            if attempt == 2 {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try? configureAudioSession(session, useSystemVoiceProcessing: useSystemVoiceProcessing)
            }
            Thread.sleep(forTimeInterval: 0.05)
            format = input.inputFormat(forBus: 0)
        }
        DiagLog.log("recorder", "等待后输入格式仍未就绪,\(audioRouteDiagnostics(session: session, format: format))")
        return nil
    }

    private func audioRouteDiagnostics(session: AVAudioSession, format: AVAudioFormat) -> String {
        func names(_ inputs: [AVAudioSessionPortDescription]) -> String {
            let values = inputs.map { "\($0.portName)(\($0.portType.rawValue))" }
            return values.isEmpty ? "none" : values.joined(separator: ",")
        }
        let availableInputs = names(session.availableInputs ?? [])
        let routeInputs = names(session.currentRoute.inputs)
        return "routeInputs=\(routeInputs); availableInputs=\(availableInputs); category=\(session.category.rawValue); mode=\(session.mode.rawValue); sessionRate=\(Int(session.sampleRate)); formatRate=\(Int(format.sampleRate)); channels=\(format.channelCount)"
    }
    #endif

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
