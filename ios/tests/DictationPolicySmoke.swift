import Foundation

@main
struct DictationPolicySmoke {
    static func main() {
        precondition(DictationPolicy.meaningfulCharacterCount("一，二。 \n三！") == 3)
        precondition(DictationPolicy.meaningfulCharacterCount("。！？； \n") == 0)
        // 按常量断言,不写死秒数——默认阈值 2026-08-05 已由 20 秒下调为 10 秒。
        let threshold = DictationPolicy.defaultFullCleanupThresholdSeconds
        precondition(DictationPolicy.cleanupPromptRoute(recordingDuration: threshold - 0.001) == .homophoneOnly)
        precondition(DictationPolicy.cleanupPromptRoute(recordingDuration: threshold) == .full)
        precondition(DictationPolicy.cleanupPromptRoute(
            recordingDuration: 29, fullCleanupThresholdSeconds: 30) == .homophoneOnly)
        precondition(DictationPolicy.cleanupPromptRoute(
            recordingDuration: 30, fullCleanupThresholdSeconds: 30) == .full)
        precondition(DictationPolicy.cleanupPromptRoute(
            recordingDuration: 2, transcript: "第一说预算，第二说工期") == .explicitEnumeration)
        precondition(DictationPolicy.cleanupPromptRoute(
            recordingDuration: 120, transcript: "第一说预算，第二说工期",
            forceShortPrompt: true) == .homophoneOnly)
        precondition(DictationPolicy.cleanupPromptRoute(
            recordingDuration: 2, transcript: "首先说预算") == .homophoneOnly)
        precondition(DictationPolicy.normalizedFullCleanupThreshold(-1) == 1)
        precondition(DictationPolicy.normalizedFullCleanupThreshold(999) == 120)

        // 2026-09-06 回归审查 #3:有效纠错对完整命中,或存在非空自定义整理要求时,
        // 空转守门员必须放行整理,不能绕过用户已确认的规则。
        precondition(DictationPolicy.cleanupIsRedundant("请联系张山。"))
        precondition(!DictationPolicy.cleanupIsRedundant(
            "请联系张山。", corrections: [LearnedCorrection(source: "张山", target: "张三")]))
        precondition(!DictationPolicy.cleanupIsRedundant(
            "明天下午三点开会，地点在会议室。", customInstruction: "所有数字改用阿拉伯数字"))
        precondition(DictationPolicy.cleanupIsRedundant(
            "明天下午三点开会，地点在会议室。", customInstruction: "   "))

        let original = "。"
        let modelExplanation = "已收到您的指示。由于您提供的 ASR 原始转写内容为空，我将原样输出。"
        precondition(CleanupService.validatedOutput(modelExplanation, original: original) == original)
        precondition(CleanupService.validatedOutput("整理后的正常正文。", original: "正常正文") == "整理后的正常正文。")
        precondition(CleanupService.validatedOutput("他说：已收到您的指示。", original: "他说：已收到您的指示。") == "他说：已收到您的指示。")
        precondition(CleanupService.validatedOutput("目前31.28%", original: "目前31.283") == "目前31.283")
        precondition(CleanupService.validatedOutput("7月14日到7月15日", original: "7月14~7月15日") == "7月14日到7月15日")
        precondition(CleanupService.validatedOutput("降幅11.03%", original: "降幅11.03") == "降幅11.03%")
        precondition(CleanupService.validatedOutput("这个方案可以做。", original: "这个方案可以做，只不过时间紧。")
                     == "这个方案可以做，只不过时间紧。")
        precondition(CleanupService.validatedOutput("I MEAN，这个可以。", original: "I mean，这个可以。")
                     == "I MEAN，这个可以。")

        print("Dictation cleanup policy passed: duration routes short/full prompts, model meta text falls back.")
    }
}
