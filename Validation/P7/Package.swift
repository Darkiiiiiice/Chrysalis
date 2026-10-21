// swift-tools-version: 6.2
// 蝉蜕（Chrysalis）P7.1 可行性探针：
// Core ML 设备落点（MLComputePlan）+ 512 tile 吞吐 + 内存峰值 + 数值复核。
// 零第三方依赖；仅开发期使用，不进入 App target。
import PackageDescription

let package = Package(
    name: "P7Probe",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "p7",
            path: "Sources/p7"
        )
    ]
)
