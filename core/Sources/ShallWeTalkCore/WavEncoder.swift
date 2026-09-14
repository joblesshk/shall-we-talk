import Foundation

/// WAV(RIFF/PCM)封装:纯数据处理,不依赖 AVFoundation。
/// 供 VolcEngineASR.diagnose 生成静音测试音频;App 内真实录音仍由各自的 Recorder 负责
/// (Recorder 依赖 AVAudioEngine,属于平台重的录音层,不进本包)。
enum WavEncoder {
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
