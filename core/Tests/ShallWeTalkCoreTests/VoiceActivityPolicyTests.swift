import XCTest
@testable import ShallWeTalkCore

/// VAD 判定状态机。这一层是纯函数,所有判定错误都应该能在这里复现,
/// 而不必跑真实音频。
final class VoiceActivityPolicyTests: XCTestCase {
    /// 默认 hop 0.256s、minSpeechDuration 0.25s ⇒ 单块即可确认。
    private func makePolicy(minSpeech: TimeInterval = 0.25,
                            enter: Float = 0.5,
                            exit: Float = 0.35) -> VoiceActivityPolicy {
        VoiceActivityPolicy(config: .init(enterThreshold: enter, exitThreshold: exit,
                                          minSpeechDuration: minSpeech, hopSeconds: 0.256))
    }

    private func feed(_ policy: inout VoiceActivityPolicy,
                      _ probabilities: [Float]) -> [VoiceActivityPolicy.Step] {
        probabilities.map { policy.step(probability: $0) }
    }

    // MARK: - 迟滞:替换单阈值判定的核心理由

    /// 旧实现进入与保持共用 `raw > 0.18`,概率在阈值附近波动就反复跳进跳出,
    /// 表现为句子被拦腰截断。迟滞下沿必须让这种波动保持在语音状态。
    func testHysteresisKeepsSpeechAliveThroughDipsBelowEnterThreshold() {
        var policy = makePolicy()
        let steps = feed(&policy, [0.9, 0.42, 0.38, 0.45, 0.8])
        XCTAssertEqual(steps.map(\.isSpeech), [true, true, true, true, true],
                       "0.35–0.5 之间的波动属于迟滞带,不得判成说完")
        XCTAssertEqual(steps.compactMap(\.event), [.speechStart])
    }

    func testSpeechEndsOnlyWhenProbabilityFallsBelowExitThreshold() {
        var policy = makePolicy()
        _ = policy.step(probability: 0.9)
        let dip = policy.step(probability: 0.36)
        XCTAssertTrue(dip.isSpeech, "0.36 仍在迟滞带内")
        let end = policy.step(probability: 0.30)
        XCTAssertFalse(end.isSpeech)
        XCTAssertEqual(end.event, .speechEnd)
    }

    /// 单阈值等价于 enter == exit,此时同一串输入会来回跳变——这条测试记录
    /// 旧行为,用于说明迟滞带确实是必要的,而不是调参偏好。
    func testWithoutHysteresisTheSameInputFlaps() {
        var policy = makePolicy(enter: 0.5, exit: 0.5)
        let steps = feed(&policy, [0.9, 0.42, 0.8, 0.42])
        XCTAssertEqual(steps.map(\.isSpeech), [true, false, true, false])
        XCTAssertEqual(steps.compactMap(\.event),
                       [.speechStart, .speechEnd, .speechStart, .speechEnd],
                       "无迟滞时同一段输入会产生四次跃迁")
    }

    // MARK: - minSpeechDuration:修 hasDetectedSpeech 的锁存缺陷

    /// 旧实现单帧超阈即把 hasDetectedSpeech 永久置真,起录瞬间一声关门就会
    /// 武装自动停录,用户没开口就被 4 秒静音切断。
    func testSingleLoudBurstDoesNotCountAsSpeech() {
        var policy = makePolicy(minSpeech: 0.6)   // 需连续 3 块
        let steps = feed(&policy, [0.95, 0.1, 0.05])
        XCTAssertEqual(steps.map(\.isSpeech), [false, false, false],
                       "孤立的一块高概率是噪声,不得确认为说话")
        XCTAssertTrue(steps.compactMap(\.event).isEmpty)
    }

    func testSustainedSpeechIsConfirmedOnceMinDurationElapses() {
        var policy = makePolicy(minSpeech: 0.6)
        let steps = feed(&policy, [0.9, 0.9, 0.9])
        XCTAssertEqual(steps.map(\.isSpeech), [false, false, true])
        XCTAssertEqual(steps.compactMap(\.event), [.speechStart])
    }

    /// 必须是**连续**满足,零散帧不得累加——否则周期性噪声仍会误确认。
    func testCandidateResetsWhenInterrupted() {
        var policy = makePolicy(minSpeech: 0.6)
        let steps = feed(&policy, [0.9, 0.1, 0.9, 0.1, 0.9])
        XCTAssertTrue(steps.allSatisfy { !$0.isSpeech },
                      "间断的高概率块不得累加成一次确认")
    }

    // MARK: - 边界与生命周期

    func testExitThresholdIsClampedNotToExceedEnterThreshold() {
        let config = VoiceActivityPolicy.Config(enterThreshold: 0.4, exitThreshold: 0.9)
        XCTAssertLessThanOrEqual(config.exitThreshold, config.enterThreshold,
                                 "配置错误不得造成永远无法维持语音")
    }

    func testResetReturnsToInitialState() {
        var policy = makePolicy()
        _ = policy.step(probability: 0.9)
        XCTAssertTrue(policy.isSpeaking)
        policy.reset()
        XCTAssertFalse(policy.isSpeaking)
        // 复位后候选计数也必须清零,否则下一次录音的第一块会被直接确认。
        var strict = makePolicy(minSpeech: 0.6)
        _ = strict.step(probability: 0.9)
        strict.reset()
        XCTAssertFalse(strict.step(probability: 0.9).isSpeech)
    }

    func testSilenceOnlyStreamNeverReportsSpeech() {
        var policy = makePolicy()
        let steps = feed(&policy, [0.01, 0.2, 0.34, 0.0])
        XCTAssertTrue(steps.allSatisfy { !$0.isSpeech })
        XCTAssertTrue(steps.compactMap(\.event).isEmpty)
    }
}

/// 定长分块缓冲。模型每次要正好 4096 个样本,而录音链路给的是变长块。
final class HopAccumulatorTests: XCTestCase {
    private func pcm(samples: [Int16]) -> Data {
        var copy = samples
        return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    func testEmitsOnlyCompleteHops() {
        var accumulator = HopAccumulator(hopSamples: 4)
        XCTAssertEqual(accumulator.append(int16PCM: pcm(samples: [1, 2, 3])).count, 0)
        let hops = accumulator.append(int16PCM: pcm(samples: [4, 5]))
        XCTAssertEqual(hops.count, 1, "凑满 4 个样本才产出一块")
        XCTAssertEqual(hops[0].count, 4)
    }

    func testEmitsMultipleHopsFromOneLargeChunk() {
        var accumulator = HopAccumulator(hopSamples: 2)
        let hops = accumulator.append(int16PCM: pcm(samples: [1, 2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(hops.count, 3)
        XCTAssertEqual(accumulator.flush()?.count, 2, "残留的 1 个样本补零成一块")
    }

    func testInt16IsNormalisedToMinusOneToOne() {
        var accumulator = HopAccumulator(hopSamples: 2)
        let hops = accumulator.append(int16PCM: pcm(samples: [32767, -32768]))
        XCTAssertEqual(hops[0][0], 32767.0 / 32768, accuracy: 1e-6)
        XCTAssertEqual(hops[0][1], -1.0, accuracy: 1e-6)
    }

    func testFlushReturnsNilWhenNothingBuffered() {
        var accumulator = HopAccumulator(hopSamples: 4)
        XCTAssertNil(accumulator.flush())
        _ = accumulator.append(int16PCM: pcm(samples: [1, 2, 3, 4]))
        XCTAssertNil(accumulator.flush(), "整块已产出后不应再有残留")
    }
}
