// swift-tools-version: 5.9
import PackageDescription

// ShallWeTalkCore:iOS/macOS 两端共用的口述整理服务层(ASR 客户端、流式会话、
// LLM 单次整理调用、Prompt 构建、词典自动学习)。
// 平台版本对齐两端现有工程配置:iOS 16(project.yml options.deploymentTarget.iOS,
// 主 App target 另设 18.0 但不下探本包最低支持),macOS 14(VoicePen.xcodeproj
// MACOSX_DEPLOYMENT_TARGET)。
let package = Package(
    name: "ShallWeTalkCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShallWeTalkCore", targets: ["ShallWeTalkCore"]),
        .executable(name: "ASRABRunner", targets: ["ASRABRunner"]),
        .executable(name: "CleanupPromptExperiment", targets: ["CleanupPromptExperiment"]),
        .executable(name: "EditPassExperiment", targets: ["EditPassExperiment"]),
    ],
    targets: [
        // Silero VAD(MIT)的 CoreML 模型约 1MB,作为 SPM 资源随包分发——
        // iOS 主 App 与 macOS App 都通过 Bundle.module 拿到同一份,不必在两个
        // 工程文件里各配一次。键盘扩展不链接本包,也不跑 VAD,不受影响。
        .target(
            name: "ShallWeTalkCore",
            resources: [.copy("Resources/silero-vad-unified-256ms-v6.2.1.mlmodelc")]
        ),
        .executableTarget(name: "ASRABRunner", dependencies: ["ShallWeTalkCore"]),
        .executableTarget(name: "CleanupPromptExperiment", dependencies: ["ShallWeTalkCore"]),
        .executableTarget(name: "EditPassExperiment", dependencies: ["ShallWeTalkCore"]),
        .testTarget(name: "ShallWeTalkCoreTests", dependencies: ["ShallWeTalkCore"]),
    ]
)
