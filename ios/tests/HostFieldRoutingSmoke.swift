import Foundation

/// 输入框语义路由(`HostFieldKind`)。
///
/// 该类型是 iOS 独有的,住在 `_sources/Shared/` 而不是 ShallWeTalkCore,因此覆盖不了
/// core 的 XCTest;沿用 `DictationPolicySmoke` 的模式,由 swiftc 直接编译断言。
@main
struct HostFieldRoutingSmoke {
    static func main() {
        // 邮箱/网址/数字框:不调 LLM。
        precondition(HostFieldKind.restricted.cleanupPolicy == .skipCleanup)
        // 搜索框:忽略录音时长,强制短路由;IM 发送框:按录音时长路由长口述。
        precondition(HostFieldKind.search.cleanupPolicy == .forceShort)
        precondition(HostFieldKind.messaging.cleanupPolicy == .byDuration)
        // 普通文本框与 IM 发送框按录音时长路由。
        precondition(HostFieldKind.general.cleanupPolicy == .byDuration)

        // 搜索框由程序删除中英文标点并压平换行；其他输入框不得改动交付文字。
        precondition(HostFieldKind.search.textForDelivery("香港，机场。 MacBook-Pro？\n商务舱！")
                     == "香港机场 MacBookPro 商务舱")
        precondition(HostFieldKind.search.textForDelivery("C++   Swift") == "C++ Swift")
        precondition(HostFieldKind.messaging.textForDelivery("你好，世界！") == "你好，世界！")
        precondition(HostFieldKind.general.textForDelivery("第一、第二。") == "第一、第二。")

        // rawValue 是跨进程桥快照的实际载荷,改名会让旧快照静默降级为 general。
        precondition(HostFieldKind.general.rawValue == "general")
        precondition(HostFieldKind.search.rawValue == "search")
        precondition(HostFieldKind.messaging.rawValue == "messaging")
        precondition(HostFieldKind.restricted.rawValue == "restricted")
        precondition(HostFieldKind(rawValue: "unknown-from-future-build") == nil)

        // 桥快照缺字段(升级前落盘的旧快照)必须解码成功并回落 general,
        // 否则键盘请求会在主 App 侧整条失效。
        let legacy = #"{"fieldKind":null}"#.data(using: .utf8)!
        struct Probe: Codable { var fieldKind: HostFieldKind? = nil }
        precondition((try? JSONDecoder().decode(Probe.self, from: legacy))?.fieldKind == nil)
        let missing = "{}".data(using: .utf8)!
        precondition((try? JSONDecoder().decode(Probe.self, from: missing))?.fieldKind == nil)

        print("HostFieldRoutingSmoke: OK")
    }
}
