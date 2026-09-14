import UIKit

/// Return only to the host observed for this exact cold keyboard request.
@MainActor
enum ColdReturnCoordinator {
    private static var generation = UUID()
    private static var attemptedThisLaunch = false

    static func resetForNewForegroundSession() {
        generation = UUID()
        attemptedThisLaunch = false
    }

    static func attemptReturn(requestID: String, target: HostReturnTarget, requestAt: TimeInterval,
                              reason: String,
                              isStillEligible: @escaping @MainActor () -> Bool,
                              hasFreshAudio: @escaping @MainActor () -> Bool) async {
        guard !attemptedThisLaunch else { return }
        attemptedThisLaunch = true
        let token = generation
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            guard token == generation, !Task.isCancelled, isStillEligible(),
                  KeyboardBridgeStore.snapshot().requestID == requestID,
                  target.isValidForReturn(requestAt: requestAt, now: Date().timeIntervalSince1970) else {
                trace("取消或请求过期 request=\(requestID)"); return
            }
            guard UIApplication.shared.applicationState == .active else {
                trace("App 已离开前台；不视为返回成功 request=\(requestID)"); return
            }
            if hasFreshAudio() {
                let sample = SWTHostSample()
                if let pid = sample["pid"] as? NSNumber, pid.intValue == target.pid,
                   let bundle = sample["bundle"] as? String, !bundle.isEmpty, bundle != target.bundleID {
                    trace("拒绝冲突身份 request=\(requestID)"); return
                }
                let accepted = SWTOpenHostApplication(target.bundleID)
                trace("打开宿主 request=\(requestID) bundle=\(target.bundleID) accepted=\(accepted) reason=\(reason)；仍需键盘/字段验收")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        trace("等待本次音频样本超时 request=\(requestID)")
    }

    private static func trace(_ message: String) {
        DictationController.recordTrace("[冷返回] \(message)")
    }
}
