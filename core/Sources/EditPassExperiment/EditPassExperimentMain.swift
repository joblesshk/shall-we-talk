import Foundation
import ShallWeTalkCore

/// 修改模式(语音二次修改-执行方略.md v2 §9)的离线评测语料条目。
///
/// 语料必须是真实的描述式修改口述("一直做多的直,不是一只的只"),不能用"把 A 改成 B"
/// 这种规整句子凑数——那样调出来的 prompt 是对着生产里不存在的输入形态优化的。
/// `expectNoEdit == true` 时 `expected` 可以省略,这类样本只参与"认输率"统计。
private struct EditCase: Codable, Sendable {
    let id: String?
    let original: String
    let instruction: String
    let expected: String?
    let expectNoEdit: Bool?

    var isNoEditCase: Bool { expectNoEdit ?? false }
}

private struct EditCaseResult: Codable, Sendable {
    let id: String
    let original: String
    let instruction: String
    let expected: String?
    let expectNoEdit: Bool
    let outcomeLabel: String
    let output: String?
    let milliseconds: Int
    let error: String?
    /// 一次成功率的判定:非 expectNoEdit 样本里,输出与期望稿逐字相同。
    let exactMatch: Bool
    /// 附带破坏率的判定:输出改动了期望稿之外的原文位置。
    let hasCollateralDamage: Bool
    /// 认输率的判定:expectNoEdit 样本里,确实判定为 noEdit。
    let concededCorrectly: Bool
}

@main
private enum EditPassExperiment {
    static func main() async throws {
        guard let corpusPath = argumentValue("--corpus") else {
            throw runnerError("必须传 --corpus <语料 JSON 路径>,格式见 EditPassExperimentMain.swift 顶部注释")
        }
        let corpusURL = URL(fileURLWithPath: corpusPath)
        let cases = try JSONDecoder().decode([EditCase].self, from: Data(contentsOf: corpusURL))
        guard !cases.isEmpty else { throw runnerError("语料文件是空数组") }

        // 复用 App 里已经配置好的 LLM provider(与 CleanupPromptExperiment 同一读法),
        // 不另外要求传 --key/--model——本机跑评测时这些早就在 App 设置里配好了。
        let defaults = UserDefaults(suiteName: "org.example.VoicePen")!
        let provider = defaults.string(forKey: "llmProvider") ?? "deepseek"
        let baseURLString: String
        let model: String
        let key: String
        switch provider {
        case "ark":
            baseURLString = "https://ark.cn-beijing.volces.com/api/v3"
            model = defaults.string(forKey: "arkModel") ?? "doubao-seed-1.6-flash"
            key = defaults.string(forKey: "arkKey") ?? ""
        case "custom":
            baseURLString = defaults.string(forKey: "llmBaseURL") ?? "https://api.deepseek.com/v1"
            model = defaults.string(forKey: "llmModel") ?? "deepseek-flash"
            key = defaults.string(forKey: "llmKey") ?? ""
        default:
            baseURLString = "https://api.deepseek.com/v1"
            model = defaults.string(forKey: "llmModel") ?? "deepseek-flash"
            key = defaults.string(forKey: "llmKey") ?? ""
        }
        guard !key.isEmpty else { throw runnerError("当前文字整理 API Key 未配置(在 App 设置里配置后再跑)") }
        guard let baseURL = URL(string: baseURLString) else { throw runnerError("文字整理服务地址无效") }
        let dictionary = unique(parseLines(defaults.string(forKey: "userDictionary") ?? "")
            + parseLines(defaults.string(forKey: "autoDictionary") ?? ""))
        let service = CleanupService(baseURL: baseURL, apiKey: key, model: model)

        print("开始修改模式评测:\(cases.count) 条;模型=\(model)。")
        var results: [EditCaseResult] = []
        for (index, testCase) in cases.enumerated() {
            let id = testCase.id ?? "case-\(index + 1)"
            let result = await run(id: id, testCase: testCase, service: service, dictionary: dictionary)
            let state = result.error != nil ? "FAIL" : (result.exactMatch || result.concededCorrectly ? "OK" : "MISS")
            print("[\(index + 1)/\(cases.count)] \(state) \(result.milliseconds)ms \(id)")
            results.append(result)
        }

        let reportPath = argumentValue("--out") ?? defaultReportPath()
        try markdown(results: results, model: model).write(
            toFile: reportPath, atomically: true, encoding: .utf8)
        print("REPORT_MD \(reportPath)")
    }

    private static func run(id: String, testCase: EditCase, service: CleanupService,
                            dictionary: [String]) async -> EditCaseResult {
        let started = Date()
        do {
            let outcome = try await EditPass.run(
                original: testCase.original, instruction: testCase.instruction,
                llm: service, dictionary: dictionary) { _ in }
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            let outcomeLabel: String
            let output: String?
            switch outcome {
            case .applied(let text): outcomeLabel = "applied"; output = text
            case .flaggedLargeChange(let text): outcomeLabel = "flaggedLargeChange"; output = text
            case .noEdit: outcomeLabel = "noEdit"; output = nil
            case .unchanged: outcomeLabel = "unchanged"; output = testCase.original
            }
            let exactMatch = !testCase.isNoEditCase && output != nil
                && output!.trimmingCharacters(in: .whitespacesAndNewlines)
                    == (testCase.expected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let collateral = !testCase.isNoEditCase && output != nil && testCase.expected != nil
                ? hasCollateralDamage(original: testCase.original, output: output!, expected: testCase.expected!)
                : false
            let conceded = testCase.isNoEditCase && outcomeLabel == "noEdit"
            return EditCaseResult(
                id: id, original: testCase.original, instruction: testCase.instruction,
                expected: testCase.expected, expectNoEdit: testCase.isNoEditCase,
                outcomeLabel: outcomeLabel, output: output, milliseconds: elapsed, error: nil,
                exactMatch: exactMatch, hasCollateralDamage: collateral, concededCorrectly: conceded)
        } catch {
            return EditCaseResult(
                id: id, original: testCase.original, instruction: testCase.instruction,
                expected: testCase.expected, expectNoEdit: testCase.isNoEditCase,
                outcomeLabel: "error", output: nil,
                milliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                error: error.localizedDescription, exactMatch: false,
                hasCollateralDamage: false, concededCorrectly: false)
        }
    }

    /// 附带破坏率的近似判定:用 LCS 对齐原文分别与「实际输出」「期望输出」比较,
    /// 拿到两组"原文里被动过的字符位置";实际输出动过、期望输出没动过的位置,
    /// 就是修改要求没覆盖到却被改了的地方。
    private static func hasCollateralDamage(original: String, output: String, expected: String) -> Bool {
        let originalChars = Array(original)
        let touchedByOutput = changedOriginalIndices(from: originalChars, to: Array(output))
        let touchedByExpected = changedOriginalIndices(from: originalChars, to: Array(expected))
        return !touchedByOutput.subtracting(touchedByExpected).isEmpty
    }

    /// LCS 对齐后,不在最长公共子序列里的 `a` 下标即视为"被改动"(删除或替换)。
    private static func changedOriginalIndices(from a: [Character], to b: [Character]) -> Set<Int> {
        guard !a.isEmpty else { return [] }
        guard !b.isEmpty else { return Set(a.indices) }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        var matched = Set<Int>()
        var i = a.count, j = b.count
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                matched.insert(i - 1)
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return Set(a.indices).subtracting(matched)
    }

    private static func defaultReportPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shall We Talk", isDirectory: true)
            .appendingPathComponent("bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("edit-pass-\(stamp).md").path
    }

    private static func markdown(results: [EditCaseResult], model: String) -> String {
        let scored = results.filter { $0.error == nil }
        let noEditCases = scored.filter { $0.expectNoEdit }
        let editCases = scored.filter { !$0.expectNoEdit }
        let collateralRate = editCases.isEmpty ? nil
            : Double(editCases.filter(\.hasCollateralDamage).count) / Double(editCases.count)
        let oneShotRate = editCases.isEmpty ? nil
            : Double(editCases.filter(\.exactMatch).count) / Double(editCases.count)
        let concedeRate = noEditCases.isEmpty ? nil
            : Double(noEditCases.filter(\.concededCorrectly).count) / Double(noEditCases.count)
        let p50 = median(results.map(\.milliseconds))

        var lines = [
            "# 修改模式(EditPass)离线评测",
            "",
            "模型:\(model) · 语料:\(results.count) 条(修改样本 \(editCases.count) · 认输样本 \(noEditCases.count))",
            "",
            "## §9 四项指标",
            "",
            "| 指标 | 数值 | 建议闸门 |",
            "|---|---|---|",
            "| 附带破坏率 | \(percent(collateralRate)) | = 0,出现一条就不上线 |",
            "| 一次成功率 | \(percent(oneShotRate)) | ≥ 80% |",
            "| 认输率 | \(percent(concedeRate)) | 越高越好 |",
            "| p50 延迟 | \(p50) | ≤ 2.5s(此处单位 ms) |",
            "",
            "## 未达标样本",
            "",
        ]
        let misses = results.filter { result in
            result.error != nil
                || (!result.expectNoEdit && !result.exactMatch)
                || (!result.expectNoEdit && result.hasCollateralDamage)
                || (result.expectNoEdit && !result.concededCorrectly)
        }
        if misses.isEmpty {
            lines.append("(无)")
        } else {
            for miss in misses {
                lines.append("### \(miss.id)")
                lines.append("- 原文:\(miss.original)")
                lines.append("- 修改要求:\(miss.instruction)")
                if let expected = miss.expected { lines.append("- 期望:\(expected)") }
                lines.append("- 实际:\(miss.output ?? miss.outcomeLabel)")
                if let error = miss.error { lines.append("- 错误:\(error)") }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func median(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "—" }
        let sorted = values.sorted()
        return "\(sorted[sorted.count / 2])ms"
    }

    private static func argumentValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func parseLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func runnerError(_ message: String) -> NSError {
        NSError(domain: "EditPassExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
