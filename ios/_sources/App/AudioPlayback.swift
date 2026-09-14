import SwiftUI
import AVFoundation

/// 备忘原音回放:一次只放一条(再开一条会停掉上一条);播放按钮态与进度由此驱动。
///
/// 会话隔离:播放用 .playback 类目,且**绝不**在录音/整理进行中激活(调用方传 blocked 守卫),
/// 避免与录音的 .playAndRecord 会话打架;停止时主动 setActive(false) 让路,下次录音照常。
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var progress: Double = 0   // 0...1
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// 只有本对象真正激活过 .playback 会话时才为 true。
    /// RecordView 在 phase 进入 .recording 时会调用 stop() 作为保险;
    /// 若当时并未播放,stop() 绝不能关闭 Recorder 刚激活的麦克风会话。
    private var ownsActiveSession = false

    func isPlaying(_ id: UUID) -> Bool { playingID == id }

    /// 播放/停止某条记录的原音。同 id 再点=停;blocked=true(录音/整理中)时拒绝。
    func toggle(url: URL, id: UUID, blocked: Bool) {
        if playingID == id { stop(); return }
        stop()   // 只允许一条同时播放
        guard !blocked else {
            DiagLog.log("playback", "已拦截:录音或整理进行中 id=\(id.uuidString.suffix(8))")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            DiagLog.log("playback", "文件不存在 id=\(id.uuidString.suffix(8)) path=\(url.lastPathComponent)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            ownsActiveSession = true
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else {
                DiagLog.log("playback", "AVAudioPlayer.play 返回 false id=\(id.uuidString.suffix(8))")
                deactivate()
                return
            }
            player = p
            playingID = id
            progress = 0
            currentTime = 0
            duration = p.duration
            DiagLog.log("playback", "开始播放 id=\(id.uuidString.suffix(8)) file=\(url.lastPathComponent) duration=\(String(format: "%.2f", p.duration))s")
            Haptics.impact(.light)
            startTicker()
        } catch {
            let e = error as NSError
            DiagLog.log("playback", "启动失败 id=\(id.uuidString.suffix(8)) \(e.domain) \(e.code): \(e.localizedDescription)")
            deactivate()
        }
    }

    func stop() {
        let hadPlaybackSession = ownsActiveSession
        ticker?.invalidate(); ticker = nil
        player?.stop(); player = nil
        playingID = nil
        progress = 0
        currentTime = 0
        duration = 0
        if hadPlaybackSession { deactivate() }
    }

    private func startTicker() {
        ticker?.invalidate()
        // Timer 挂在主 run loop,回调即在主线程更新 @Published,进度条随播放推进
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            self.currentTime = p.currentTime
            self.duration = p.duration
            self.progress = min(1, p.currentTime / p.duration)
        }
    }

    private func deactivate() {
        guard ownsActiveSession else { return }
        ownsActiveSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}
