import Foundation

/// 插入边界感知:把整理稿放进宿主输入框之前,按光标前后已有的内容做最小调整。
///
/// 动机是整理稿本身是"一段独立的话",而宿主输入框里可能已经有内容。此前两端都原样插入,
/// 于是在英文后面接着口述会粘成一个词(`The valuation isroughly 30x`),在已有句号前插入
/// 会留下双重标点。
///
/// 刻意做成纯函数并保持极窄的改动范围——它跑在保真链路的最后一步,任何"顺手润色"都会
/// 越过 `PromptBuilder` 的保真边界。因此只处理三件确定性的事:词间空格、重复句末标点、
/// 输入框开头的首字母大写。中英文之间不加空格:那是排版偏好而非正确性问题,系统输入法
/// 同样不加,擅自加会改变用户已有的书写习惯。
public enum InsertionBoundary {
    /// - Parameters:
    ///   - text: 待插入的整理稿。
    ///   - before: 光标前的上下文(iOS 取 `documentContextBeforeInput`)。取不到时传 nil,
    ///             此时一律不加前导空格——宁可不加也不能在未知上下文里凭空插空格。
    ///   - after: 光标后的上下文(iOS 取 `documentContextAfterInput`)。
    ///   - capitalizeSentenceStart: 宿主是否声明了句首自动大写
    ///     (`autocapitalizationType == .sentences`)。只有宿主明确要求时才动大小写,
    ///     因为 `PromptBuilder` 对整理环节写死了"不调整大小写"。
    public static func adjust(text: String,
                              before: String?,
                              after: String?,
                              capitalizeSentenceStart: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        var output = text

        if capitalizeSentenceStart, isAtFieldStart(before), let first = output.first,
           first.isLowercase, first.isASCII {
            output.replaceSubrange(output.startIndex...output.startIndex,
                                   with: String(first).uppercased())
        }

        if let last = output.last, let next = after?.first, last == next,
           DictationPolicy.sentenceEnds.contains(last) {
            output.removeLast()
        }

        if needsLeadingSpace(text: output, before: before) {
            output = " " + output
        }
        return output
    }

    /// 光标停在一个空输入框的开头(只有空白也算开头)。
    private static func isAtFieldStart(_ before: String?) -> Bool {
        guard let before else { return false }
        return before.allSatisfy(\.isWhitespace)
    }

    /// 只在"两侧都是 ASCII 字母或数字"时补空格——这是唯一会真正把两个词粘成一个词的情况。
    ///
    /// 中英之间不补:`我们讨论了` + `valuation` 粘在一起仍然可读且可分词,补空格属于排版偏好。
    /// 前文已以空白结尾、整理稿已以空白或标点开头、前文取不到时,一律不补。
    private static func needsLeadingSpace(text: String, before: String?) -> Bool {
        guard let previous = before?.last, let first = text.first else { return false }
        return isASCIIWordCharacter(previous) && isASCIIWordCharacter(first)
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
