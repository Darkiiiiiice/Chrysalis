// swift-tools-version: 6.2
// 蝉蜕（Chrysalis）P6 验证 harness：单元测试 + 集成测试 + 性能/内存基准。
// Core/ 为指向应用源码目录的符号链接（git 支持跟踪 symlink），零第三方依赖。
// 用法：swift run check [all|unit|integration|bench|list]
import PackageDescription

let package = Package(
    name: "ChrysalisHarness",
    platforms: [
        // 与应用一致：核心代码使用 macOS 26 的新 AVFoundation API
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "check",
            path: "Sources/check"
        )
    ]
)
