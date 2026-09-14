import Foundation

/// 标准电话九键映射。所有拼音数字码均由本工程自己的合法音节/词典生成，
/// 不携带外部输入法项目的生成常量。
enum T9KeyMap {
    private static let letterToDigit: [Character: Character] = {
        let groups: [(Character, String)] = [
            ("2", "abc"), ("3", "def"), ("4", "ghi"), ("5", "jkl"),
            ("6", "mno"), ("7", "pqrs"), ("8", "tuv"), ("9", "wxyz")
        ]
        var result: [Character: Character] = [:]
        for (digit, letters) in groups {
            for letter in letters { result[letter] = digit }
        }
        return result
    }()

    static func code(for text: String) -> String? {
        var result = ""
        for letter in text.lowercased() {
            guard let digit = letterToDigit[letter] else { return nil }
            result.append(digit)
        }
        return result.isEmpty ? nil : result
    }

    static func normalizedDigits(_ input: String) -> String {
        String(input.filter { ("2"..."9").contains(String($0)) })
    }

    static func isInputDigit(_ character: Character) -> Bool {
        ("2"..."9").contains(String(character))
    }
}
