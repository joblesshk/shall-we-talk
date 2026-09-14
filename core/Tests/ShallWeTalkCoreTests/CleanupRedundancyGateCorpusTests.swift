import XCTest
@testable import ShallWeTalkCore

/// 用真实语料复核空转守门员的覆盖率与纯度。
///
/// 不内置语料路径,由 `GATE_CORPUS` 指定一份 `paired-cases.jsonl`
/// (格式见 `开发数据/真实语音评测/*/dataset/`);未设置时整个测试跳过,
/// 保证 `swift test` 在没有开发数据的环境下仍然全绿。
///
/// 它守的是一件单元测试守不住的事:阈值当初是在 Python 里调的,
/// 而线上跑的是 Swift。两边任何一处判定漂移,这里的覆盖率/纯度就会掉出下界。
/// 下界比实测留出值(覆盖 51%、纯度 91%)各留了几个点的余量,
/// 只在真正退化时报警,不因为换一份语料就红。
final class CleanupRedundancyGateCorpusTests: XCTestCase {

    private struct Sample {
        let raw: String
        let clean: String
        var isNoOp: Bool { raw == clean }
    }

    func testGateHoldsCoverageAndPurityOnRealCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["GATE_CORPUS"], !path.isEmpty else {
            throw XCTSkip("set GATE_CORPUS to a paired-cases.jsonl to run the corpus check")
        }
        let dictionary = (env["GATE_DICTIONARY"] ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        var samples: [Sample] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metrics = object["historical_metrics"] as? [String: Any],
                  // 与调参口径一致:只统计停止后真的发过 LLM 请求的那些。
                  metrics["llmFirstTokenMillis"] is Int,
                  let raw = object["raw_text"] as? String,
                  let clean = object["clean_text"] as? String
            else { continue }
            samples.append(Sample(raw: raw, clean: clean))
        }
        try XCTSkipIf(samples.count < 100, "语料样本不足 100 条,统计无意义")

        let passed = samples.filter { DictationPolicy.cleanupIsRedundant($0.raw, dictionaryWords: dictionary) }
        let missed = passed.filter { !$0.isNoOp }
        let coverage = Double(passed.count) / Double(samples.count)
        let purity = Double(passed.count - missed.count) / Double(max(passed.count, 1))

        print(String(format: "空转守门员语料复核: n=%d 覆盖=%.0f%% 纯度=%.0f%% 漏判=%d 期望省下=%.2fs",
                     samples.count, coverage * 100, purity * 100, missed.count, coverage * 0.87))

        XCTAssertGreaterThan(coverage, 0.45, "覆盖率跌破下界,守门员基本不再放行")
        XCTAssertGreaterThan(purity, 0.85, "纯度跌破下界,放行的里面太多其实需要整理")
    }
}
