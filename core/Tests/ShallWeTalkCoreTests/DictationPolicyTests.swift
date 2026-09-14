import XCTest
@testable import ShallWeTalkCore

final class DictationPolicyTests: XCTestCase {
    func testTimeoutReturnsBeforeCancellationInsensitiveOperationFinishes() async {
        let start = Date()
        let result: String? = await DictationPolicy.withTimeout(seconds: 0.02) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(returning: "late")
                }
            }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "Timeout must not await a cancellation-insensitive child")
        // Let the losing operation complete to exercise double-resume protection.
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    func testCallerCancellationEndsDeadlineWait() async {
        let task = Task {
            await DictationPolicy.withTimeout(seconds: 10) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return "cancelled"
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
    func testLightCleanupAlwaysUsesShortPromptRoute() {
        XCTAssertEqual(
            DictationPolicy.cleanupPromptRoute(
                recordingDuration: 120,
                transcript: "第一说预算，第二说工期",
                forceShortPrompt: true),
            .homophoneOnly)
    }

    func testCleanupPromptRouteUsesRecordingDurationBoundary() {
        // 按常量断言,不写死秒数——默认阈值 2026-08-05 已由 20 秒下调为 10 秒,
        // 后续再调不应该连带改测试。恰好达到阈值算长口述。
        let threshold = DictationPolicy.defaultFullCleanupThresholdSeconds
        XCTAssertEqual(DictationPolicy.cleanupPromptRoute(recordingDuration: threshold - 0.001),
                       .homophoneOnly)
        XCTAssertEqual(DictationPolicy.cleanupPromptRoute(recordingDuration: threshold), .full)
        XCTAssertEqual(DictationPolicy.cleanupPromptRoute(recordingDuration: 45, fullCleanupThresholdSeconds: 60),
                       .homophoneOnly)
        XCTAssertEqual(DictationPolicy.cleanupPromptRoute(recordingDuration: 60, fullCleanupThresholdSeconds: 60),
                       .full)
    }

    func testCleanupThresholdIsClampedToSupportedRange() {
        XCTAssertEqual(DictationPolicy.normalizedFullCleanupThreshold(-1), 1)
        XCTAssertEqual(DictationPolicy.normalizedFullCleanupThreshold(20), 20)
        XCTAssertEqual(DictationPolicy.normalizedFullCleanupThreshold(999), 120)
        XCTAssertEqual(DictationPolicy.cleanupPromptRoute(recordingDuration: -3), .homophoneOnly)
    }

    func testPairedEnumerationSignalsOverrideDurationRoute() {
        for transcript in [
            "第一，先确认预算。第二，再确定时间。",
            "首先确认需求，其次安排开发。",
            "一是控制风险，二是提高效率。",
            "其一是成本，其二是工期。",
        ] {
            XCTAssertTrue(DictationPolicy.containsExplicitEnumerationSignals(transcript))
            XCTAssertEqual(
                DictationPolicy.cleanupPromptRoute(recordingDuration: 2, transcript: transcript),
                .explicitEnumeration)
        }
    }

    func testSingleOrReversedEnumerationSignalDoesNotOverrideDurationRoute() {
        for transcript in ["首先确认需求。", "我只有第一点。", "其次再说第一点。", "二是成本，一是工期。"] {
            XCTAssertFalse(DictationPolicy.containsExplicitEnumerationSignals(transcript))
            XCTAssertEqual(
                DictationPolicy.cleanupPromptRoute(recordingDuration: 2, transcript: transcript),
                .homophoneOnly)
        }
    }

    func testMeaningfulCharacterCountRemainsAvailableForDiagnostics() {
        XCTAssertEqual(DictationPolicy.meaningfulCharacterCount("一，二。 \n三！"), 3)
    }

    func testSharedTimeoutReturnsNilWhenOperationDoesNotFinish() async {
        let result: String? = await DictationPolicy.withTimeout(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return "late"
        }
        XCTAssertNil(result)
    }
}

/// 整段仅含纯发声停顿的判定(2026-08-03)。历史里出现过整段只有"嗯。"的录音,
/// 旧链路会因为整理结果为空而兜底回退成 ASR 原文,把"嗯。"插进用户文档。
final class PureFilledPauseTests: XCTestCase {
    func testDetectsUtterancesMadeEntirelyOfFilledPauses() {
        for text in ["嗯。", "嗯", "呃……", "嗯，呃。", "Uh.", "um, uh", "唔？", "Hmm."] {
            XCTAssertTrue(DictationPolicy.isPureFilledPause(text), "\(text) should count as pure filler")
        }
    }

    func testKeepsRealContentEvenWhenItContainsPauseCharacters() {
        // 逐字判定会误伤这些:"额"在金额里、"唔"在粤语里、停顿音后面还有正文。
        for text in ["这笔金额我再确认一下。", "我都唔知佢识唔识。", "嗯，我同意。",
                     "呃，明天把合同发出去。", "余额不足", "number"] {
            XCTAssertFalse(DictationPolicy.isPureFilledPause(text), "\(text) carries real content")
        }
    }

    func testEmptyOrPunctuationOnlyIsNotReportedAsFilledPause() {
        // 空输入由既有的"没有识别到内容"判断处理,这里不重复接管。
        for text in ["", "   ", "。。。", "\n"] {
            XCTAssertFalse(DictationPolicy.isPureFilledPause(text))
        }
    }
}

/// 停顿自动停录的判定(2026-08-05)。用户反馈:思考一句话的下半句该怎么说时会停顿
/// 相当长的时间,而旧实现对"说完了的停顿"和"想词的停顿"用同一个阈值,把话拦腰截断。
final class AutoStopOnSilenceTests: XCTestCase {
    /// 回归钉:全角 ！？； 曾被悄悄换成半角同形字,集合去重后只剩四个字符,
    /// 以 ？结尾的中文句子因此从来不被认作句末。按码位断言,字形看不出来的退化也能拦住。
    func testSentenceEndsCoverBothWidths() {
        let expected: Set<Character> = ["\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF1B}", "!", "?", ";"]
        XCTAssertEqual(DictationPolicy.sentenceEnds, expected)
        XCTAssertEqual(DictationPolicy.sentenceEnds.count, 7,
                       "full-width and half-width forms must be distinct members, not deduped look-alikes")
        for text in ["这个方案可以做？", "太好了！", "先谈价格；", "Can we ship it?", "Ship it!"] {
            XCTAssertTrue(DictationPolicy.endsAtSentenceBoundary(text), "\(text) ends a sentence")
        }
        // 句末判定只看最后一个字符:标点出现在句中不算说完。
        for text in ["我觉得这个方案", "先谈价格；再谈交割", "合同、打款", "他说,"] {
            XCTAssertFalse(DictationPolicy.endsAtSentenceBoundary(text), "\(text) is unfinished")
        }
    }

    func testStopsAtThresholdWhenSentenceIsComplete() {
        XCTAssertTrue(DictationPolicy.shouldAutoStop(
            silence: 4.0, threshold: 4.0, transcriptSoFar: "明天把合同发给对方。"))
        // 尾部空白不影响句末判定。
        XCTAssertTrue(DictationPolicy.shouldAutoStop(
            silence: 4.2, threshold: 4.0, transcriptSoFar: "这个方案可以做？  \n"))
    }

    func testWaitsLongerWhenStoppedMidSentence() {
        // 半句话中间的停顿:到了阈值也不停,给用户想下半句的时间。
        for silence in [4.0, 6.0, 9.9] {
            XCTAssertFalse(DictationPolicy.shouldAutoStop(
                silence: silence, threshold: 4.0, transcriptSoFar: "我觉得这个方案"),
                "silence=\(silence) 仍在半句话中间,不该停")
        }
    }

    func testStillStopsAtTheHardCeilingWithoutSentencePunctuation() {
        // ASR 迟迟不吐句末标点时不能永不结束:2.5 倍即硬上限。
        XCTAssertTrue(DictationPolicy.shouldAutoStop(
            silence: 10.0, threshold: 4.0, transcriptSoFar: "我觉得这个方案"))
    }

    func testNeverStopsBeforeThreshold() {
        XCTAssertFalse(DictationPolicy.shouldAutoStop(
            silence: 3.9, threshold: 4.0, transcriptSoFar: "明天把合同发给对方。"))
    }

    func testEmptyTranscriptCountsAsUnfinished() {
        // 还没有任何识别结果:按"没说完"处理,走放宽预算。
        XCTAssertFalse(DictationPolicy.shouldAutoStop(
            silence: 4.0, threshold: 4.0, transcriptSoFar: ""))
        XCTAssertTrue(DictationPolicy.shouldAutoStop(
            silence: 10.0, threshold: 4.0, transcriptSoFar: ""))
    }
}
