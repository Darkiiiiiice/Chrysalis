# AGENTS.md — 蝉蜕（Chrysalis）开发约定

本目录是「蝉蜕（Chrysalis）」——macOS 本地视频转码工具——的开发项目。**动手前先完整阅读 `docs/设计文档.md`，一切以它为准。**

## 先读

- `docs/设计文档.md`：目标与非目标、硬性约束、支持矩阵、技术路线、架构与状态机、转码管线、硬件加速设计（第 7 节）、TMDB 电影元数据（第 7.5 节）、UI 设计系统（第 8 节）、里程碑（P0–P6）、验收与测试、风险表、待确认项（第 13 节）。
- `README.md`：项目速览与下一步。

## 硬性约束（不可违反）

1. 纯 Swift + SwiftUI + 系统框架（AVFoundation / VideoToolbox / CoreMedia / CoreImage / Observation / Security）；**0 第三方依赖——不得引入 FFmpeg / libav 或任何转码库**；AppKit 仅限 SwiftUI 覆盖不到的最小系统集成。
2. **硬件加速是硬性要求**：默认 `RequireHardwareAcceleratedVideoEncoder = true`；无硬件编码器时任务在 `preparing` 阶段失败；**不允许静默回退软件**——软件回退只能是用户在高级设置里显式打开（默认关），并显示 `SW` 警告。
3. 支持边界（v1）：输入仅 MP4/MOV/M4V（MKV/AVI/FLV/WMV/TS/WebM 均不做）；输出仅 H.264 / HEVC / ProRes（无 AV1/VP9 编码）；HDR 检测后拒绝；不做字幕烧录/多音轨/剪辑。**不要擅自扩展支持范围。**
4. 网络仅用于 TMDB：只有任务勾选「电影」才联网；API key/token 存 Keychain，不写日志、不硬编码公共 key；关于页固定展示 "This product uses the TMDB API but is not endorsed or certified by TMDB."；不使用 TMDB 商标/logo 做应用品牌；遵守速率与缓存条款。
5. **电影元数据必须人工确认后才能开始转码**；自动匹配永不静默写入；未确认的电影任务拦截「开始全部」。
6. 输出**原子落盘**：写同目录临时文件（`.chrysalis-*.tmp`），成功后移动到最终路径；失败/取消删除临时文件；启动时清理残留；重名默认加 `-1`，不覆盖。
7. UI 遵循设计文档第 8 节：暗色优先、单一强调色（暗 `#5BE1FF` / 浅 `#007C91`）、不用霓虹/玻璃/粒子/满屏卡片、动效 120–300ms easeOut、Reduce Motion 全降级、等宽数字；颜色全部走 Asset Catalog，**视图里不写死 hex**。
8. 分发：App Sandbox + Hardened Runtime + 公证；沙盒权限最小化（仅 `network.client` 用于 TMDB；文件访问全部走安全书签）。
9. 最低系统 macOS 27.0（设计文档第 2 节，2026-10-17 已拍板）；第 13 节「待确认」项未拍板前按文档默认值执行，不要自作主张。

## 工作方式

- 按 **P0 → P1 → P2 → P3 → P4 → P5 → P6** 顺序推进；每个阶段按设计文档清单逐项完成，并以该阶段「通过标准」验收。
- 文档与实现出现冲突时：**先更新 `docs/设计文档.md` 并说明原因，再改代码**，保持文档是唯一事实来源。
- 工程创建（P0 第一项）：Xcode 工程尚未创建。优先由用户在 Xcode 新建 App 模板工程（产品名 `Chrysalis`）；请勿手工拼 `.pbxproj`。
- Swift 6 并发 + AVFoundation 非 Sendable：引擎隔离在专用串行队列；必要时 `@preconcurrency import AVFoundation`；事件用简单值类型（见设计文档第 12 节风险表）。
- 测试：用 `AVAssetWriter` 在测试里生成 2 秒测试片，仓库不放大文件；无硬件编码器的环境用 `XCTSkip` 或期望错误。
- 构建 / 测试命令：
  - `xcodebuild -project Chrysalis/Chrysalis.xcodeproj -scheme Chrysalis -configuration Debug build`（在仓库根执行；工程目录为 `Chrysalis/`，源码在 `Chrysalis/Chrysalis/`，使用文件系统同步组，新增 .swift 文件无需改工程）
  - `xcodebuild test -project Chrysalis/Chrysalis.xcodeproj -scheme Chrysalis`（暂无测试 Target，P6 添加）
- 面向用户的文案、注释与提交信息使用中文。
