import ActivityKit
import Foundation

struct CaptureActivityAttributes: ActivityAttributes {
    enum Stage: String, Codable, Hashable {
        case starting
        case standby
        case recording
        case processing
        case completed
        case failed
    }

    struct ContentState: Codable, Hashable {
        var stage: Stage
        var message: String
        var startedAt: Date
        /// 有期限待命的结束时间；录音/处理和「直到被中断」为 nil。
        var expiresAt: Date? = nil
    }

    var source: String
}
