import Foundation

/// 对纠错对做确定性、大小写不敏感的整段替换,作为 `PromptBuilder.correctionsBlock` 的
/// 兜底安全网——那条路径是喂给整理模型的自然语言指令,模型是否严格执行、是否区分大小写
/// 都不保证；整理请求失败或明确跳过整理时，prompt 指令也不会生效。
/// 这里用纯字符串替换保证"不管识别成什么样的大小写,都替换成词典写法"这个用户明确要求的
/// 强约束,与 prompt 注入并行(不是互斥),对所有纠错对(手动 + 自动挖掘)统一生效——
/// correctionsBlock 的注释本就把这类纠错定义为"确定性替换",这里只是把承诺落到实处。
public enum ManualCorrections {
    public static func apply(to text: String, pairs: [LearnedCorrection]) -> String {
        guard !text.isEmpty, !pairs.isEmpty else { return text }
        var result = text
        for pair in pairs where !pair.source.isEmpty && pair.source != pair.target {
            result = result.replacingOccurrences(of: pair.source, with: pair.target, options: [.caseInsensitive])
        }
        return result
    }
}
