import Foundation

/// 连续存储的简拼 posting。2–6 个首字母以 base-32 编码进 UInt32；a...z 使用 1...26，
/// 没有前导零，因此不同长度不会碰撞。每条固定 8 bytes，避免成千上万个小数组碎片。
struct InitialPosting {
    let code: UInt32
    let entryIndex: Int32
}

enum CompactPinyinIndex {
    static func initialsCode(_ text: String) -> UInt32? {
        guard (2...6).contains(text.count) else { return nil }
        var code: UInt32 = 0
        for scalar in text.lowercased().unicodeScalars {
            guard scalar.value >= 97, scalar.value <= 122 else { return nil }
            code = (code << 5) | UInt32(scalar.value - 96)
        }
        return code
    }
}
