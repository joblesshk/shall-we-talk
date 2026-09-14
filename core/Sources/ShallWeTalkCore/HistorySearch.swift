import Foundation

/// 记事全文搜索的纯过滤逻辑(iOS/macOS 两端共用)。
/// 约定:
/// - 多关键词以空白分隔,取 AND——全部关键词都命中才算匹配;
/// - 大小写不敏感;中文不分词,直接子串匹配;
/// - 记录量级是个人使用(几千条内),内存线性过滤足够,不引数据库/索引。
public enum HistorySearch {
    /// 把用户输入解析为关键词列表:按空白切分、去空、统一小写。
    /// 空查询/纯空白查询 → 空列表(调用方据此判断"未在搜索")。
    public static func keywords(from query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// fields 中任一字段包含某关键词即算该关键词命中;所有关键词都命中才返回 true。
    /// keywords 为空(空查询)恒为 true,便于调用方直接串在过滤管线里。
    public static func matches(fields: [String], keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return true }
        let haystacks = fields.map { $0.lowercased() }
        return keywords.allSatisfy { keyword in
            haystacks.contains { $0.contains(keyword) }
        }
    }
}
