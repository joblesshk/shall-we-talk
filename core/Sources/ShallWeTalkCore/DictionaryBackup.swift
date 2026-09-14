import Foundation

/// 可独立恢复个人词典的版本化文件；旧的 manual/auto 文件仍可读取。
public struct DictionaryBackup: Codable, Sendable {
    public var version: Int
    public var manual: [String]
    public var auto: [String]
    public var corrections: [LearnedCorrection]
    public var blockedWords: [String]
    public var blockedCorrections: [String]

    public init(manual: [String] = [], auto: [String] = [], corrections: [LearnedCorrection] = [],
                blockedWords: [String] = [], blockedCorrections: [String] = []) {
        version = 2
        self.manual = manual; self.auto = auto; self.corrections = corrections
        self.blockedWords = blockedWords; self.blockedCorrections = blockedCorrections
    }

    private enum CodingKeys: String, CodingKey { case version, manual, auto, corrections, blockedWords, blockedCorrections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...2).contains(version) else { throw ImportError.unsupportedVersion }
        manual = try c.decode([String].self, forKey: .manual)
        auto = try c.decode([String].self, forKey: .auto)
        corrections = try c.decodeIfPresent([LearnedCorrection].self, forKey: .corrections) ?? []
        blockedWords = try c.decodeIfPresent([String].self, forKey: .blockedWords) ?? []
        blockedCorrections = try c.decodeIfPresent([String].self, forKey: .blockedCorrections) ?? []
    }

    public enum ImportError: Error, LocalizedError {
        case invalidFile, unsupportedVersion
        public var errorDescription: String? {
            switch self {
            case .invalidFile: return "文件格式不正确，未导入任何内容。请选择词典 JSON 或每行一词的文本文件。"
            case .unsupportedVersion: return "此备份来自更新版本，请更新 App 后导入。"
            }
        }
    }

    public static func parse(_ data: Data, isJSON: Bool) throws -> Self {
        var result: Self
        if isJSON {
            if let words = try? JSONDecoder().decode([String].self, from: data) {
                result = Self(manual: words)
            } else {
                do { result = try JSONDecoder().decode(Self.self, from: data) }
                catch let error as ImportError { throw error }
                catch { throw ImportError.invalidFile }
            }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidFile }
            result = Self(manual: text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        func normalized(_ values: [String]) throws -> [String] {
            try values.map {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil, !value.contains("\t") else {
                    throw ImportError.invalidFile
                }
                return value
            }
        }
        result.manual = try normalized(result.manual)
        result.auto = try normalized(result.auto)
        result.blockedWords = try normalized(result.blockedWords)
        result.blockedCorrections = try normalized(result.blockedCorrections)
        result.corrections = try result.corrections.map {
            let values = try normalized([$0.source, $0.target])
            return LearnedCorrection(source: values[0], target: values[1])
        }
        return result
    }

    public struct Preview: Sendable {
        public let merged: DictionaryBackup
        public let added: Int
        public let duplicates: Int
        public let conflicts: Int
        public var message: String {
            "新增 \(added) 项，重复 \(duplicates) 项，冲突 \(conflicts) 项。\n包含词条、纠错对和屏蔽项；冲突保留本机内容，不删除本机已有词条。"
        }
    }

    /// 本机的有效条目及删除选择优先；也用于用户确认时基于最新本机状态重新合并。
    public func preview(mergingInto local: Self) -> Preview {
        var merged = local
        var added = 0, duplicates = 0, conflicts = 0
        var words = Set(local.manual + local.auto)
        var blocked = Set(local.blockedWords)
        var pairs: [String: String] = [:]
        for pair in local.corrections { pairs[pair.source.lowercased()] = pair.target }
        var blockedPairs = Set(local.blockedCorrections.map { $0.lowercased() })
        for word in blockedWords {
            if words.contains(word) { conflicts += 1 }
            else if blocked.insert(word).inserted { merged.blockedWords.append(word); added += 1 }
            else { duplicates += 1 }
        }
        for source in blockedCorrections {
            if pairs[source.lowercased()] != nil { conflicts += 1 }
            else if blockedPairs.insert(source.lowercased()).inserted { merged.blockedCorrections.append(source); added += 1 }
            else { duplicates += 1 }
        }
        for (values, isAuto) in [(manual, false), (auto, true)] {
            for word in values {
                if blocked.contains(word) { conflicts += 1 }
                else if !words.insert(word).inserted { duplicates += 1 }
                else { if isAuto { merged.auto.append(word) } else { merged.manual.append(word) }; added += 1 }
            }
        }
        for pair in corrections {
            let key = pair.source.lowercased()
            if blockedPairs.contains(key) { conflicts += 1 }
            else if let existing = pairs[key] {
                if existing == pair.target { duplicates += 1 } else { conflicts += 1 }
            } else {
                pairs[key] = pair.target; merged.corrections.append(pair); added += 1
            }
        }
        return Preview(merged: merged, added: added, duplicates: duplicates, conflicts: conflicts)
    }
}
