// swift-tools-version: 6.0
// 蝉蜕（Chrysalis）P0 技术验证工具。
// 仅用于本机实测：能力矩阵 / 硬件编码吞吐 / 取消与临时文件 / 元数据写入读回。
// 不进入 App target；零第三方依赖。
import PackageDescription

let package = Package(
    name: "P0Validation",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "p0",
            path: "Sources/p0"
        )
    ]
)
