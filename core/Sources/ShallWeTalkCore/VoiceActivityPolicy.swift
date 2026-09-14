import Foundation

/// 把 VAD 的逐块语音概率转换成「现在算不算在说话」的状态机。
///
/// 刻意与模型推理分离:这一层是纯函数,不依赖 CoreML,可直接单测。判定逻辑的错误
/// (阈值抖动、短噪声被当成说话)全部落在这里,而不是落在难以复现的音频链路上。
///
/// 替换的是两端沿用已久的单阈值判定 `raw > 0.18`。那个写法有两个结构性问题:
///
/// 1. **进入与保持共用一个阈值** → 说话音量在阈值附近波动时反复跳进跳出,
///    表现为句子被拦腰截断。这里改用迟滞:进入要高于 `enterThreshold`,
///    保持只要不低于 `exitThreshold`。
/// 2. **单帧即锁存** → 起录瞬间一声关门就让 `hasDetectedSpeech` 永久置真,
///    自动停录随即被武装,用户还没开口就被 4 秒静音切断。这里要求候选语音
///    持续满 `minSpeechDuration` 才确认。
///
/// 不做的事:静音多久算说完,由 `DictationPolicy.shouldAutoStop` 决定——那一层是
/// 产品规则(半句话中间的停顿放宽到 2.5 倍),比任何通用 VAD 的固定时长都合适。
public struct VoiceActivityPolicy: Sendable {
    public struct Config: Sendable, Equatable {
        /// 进入语音所需概率。Silero 官方推荐 0.5。
        public var enterThreshold: Float
        /// 维持语音所需概率(迟滞下沿)。必须 ≤ enterThreshold。
        public var exitThreshold: Float
        /// 候选语音需持续多久才确认为「开始说话」,用于滤掉关门、桌面碰撞这类瞬时噪声。
        public var minSpeechDuration: TimeInterval
        /// 每块音频代表的时长。256ms 是本模型的固定 hop。
        public var hopSeconds: TimeInterval

        public init(enterThreshold: Float = 0.5,
                    exitThreshold: Float = 0.35,
                    minSpeechDuration: TimeInterval = 0.25,
                    hopSeconds: TimeInterval = 0.256) {
            self.enterThreshold = enterThreshold
            self.exitThreshold = max(0, min(exitThreshold, enterThreshold))
            self.minSpeechDuration = minSpeechDuration
            self.hopSeconds = hopSeconds
        }
    }

    public enum Event: Equatable, Sendable {
        case speechStart
        case speechEnd
    }

    public struct Step: Equatable, Sendable {
        /// 本块是否计入「正在说话」。调用方据此推进 lastVoiceAt。
        public let isSpeech: Bool
        /// 状态跃迁;没有跃迁时为 nil。
        public let event: Event?
    }

    public private(set) var config: Config
    /// 已确认进入语音。
    private var speaking = false
    /// 尚未确认的候选语音已累计时长。
    private var candidateSeconds: TimeInterval = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 是否处于已确认的说话状态。
    public var isSpeaking: Bool { speaking }

    /// 喂入一块音频的语音概率,返回本块判定。
    public mutating func step(probability: Float) -> Step {
        if speaking {
            // 迟滞:已经在说话时用更低的下沿,避免音量小幅波动就判定说完。
            guard probability < config.exitThreshold else {
                return Step(isSpeech: true, event: nil)
            }
            speaking = false
            candidateSeconds = 0
            return Step(isSpeech: false, event: .speechEnd)
        }

        guard probability >= config.enterThreshold else {
            // 候选被打断即清零:必须是「连续」满足时长,而不是零散帧累加。
            candidateSeconds = 0
            return Step(isSpeech: false, event: nil)
        }

        candidateSeconds += config.hopSeconds
        guard candidateSeconds >= config.minSpeechDuration else {
            // 候选期不算说话:这正是短噪声被滤掉的位置。
            return Step(isSpeech: false, event: nil)
        }
        speaking = true
        return Step(isSpeech: true, event: .speechStart)
    }

    /// 重置到起录初态。每次开始录音前调用。
    public mutating func reset() {
        speaking = false
        candidateSeconds = 0
    }
}
