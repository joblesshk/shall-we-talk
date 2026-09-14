import Foundation

/// 可注入的诊断日志出口:本包不知道也不依赖 App 的具体日志实现(iOS 侧是跨进程共享的
/// DiagLog,macOS 侧目前没有等价物)。App 启动时按需设置 `handler`;不设置时静默丢弃,
/// 不写文件、不崩溃——与原 DiagLog 的"绝不能阻塞/崩溃"原则一致。
public enum CoreDiagLog {
    public static var handler: ((String, String) -> Void)?

    public static func log(_ component: String, _ message: String) {
        handler?(component, message)
    }
}
