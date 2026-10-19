# 蝉蜕（Chrysalis）

macOS 上的本地视频转码工具：拖入视频，批量转码为 H.264 / HEVC / ProRes，默认走 Apple 硬件媒体引擎（VideoToolbox），速度优先、CPU 占用低；可选从 TMDB 获取电影元数据，人工确认后写入 MP4/MOV 容器。纯 Swift + SwiftUI，零第三方依赖。

> 「蝉蜕」取意「金蝉脱壳」——转码即蜕变：旧壳（容器）留在身后，影像本体无损，飞向新形。英文名「Chrysalis」是蛹壳——蜕变发生的静默容器；原文件保留、输出原子落盘，正合其意。

## 状态

**P0 技术验证 / P1 单文件 MVP / P2 队列与预设已完成**（2026-10-19）。P2 通过 41 项自动化检查（10 文件批量串行、HEVC 输出 `hvc1`、取消/重试、重启恢复、重名 `-1`、预设持久化）；界面走查待用户确认。

- 已完成里程碑：P0 能力矩阵与吞吐实测（`docs/P0-实测报告.md`）；P1 单文件 H.264+AAC MP4（硬件编码、进度/取消/原子落盘、错误提示、应用图标）；P2 多文件队列（串行、取消/重试）、内置 4 预设 + 自定义预设（`presets.json`）、HEVC 预设、硬件能力矩阵（设置页）、输出目录安全书签 + 重启恢复队列（`queue.json`，活跃任务恢复为「已中断」）
- Xcode 工程：[`Chrysalis/Chrysalis.xcodeproj`](Chrysalis/Chrysalis.xcodeproj) —— 仅 macOS 27.0+、Swift 6（严格并发）、App Sandbox、Hardened Runtime
- 转码读写：macOS 27 新 AVFoundation 异步模型（`AVAssetReader.outputProvider` / `AVAssetWriter.inputReceiver`，视频/音频各一个并发泵；`AVVideoComposition.Configuration` 旋转合成）
- 构建：`xcodebuild -project Chrysalis/Chrysalis.xcodeproj -scheme Chrysalis -configuration Debug build`（当前零警告、可直接运行）
- 实测报告：[`docs/P0-实测报告.md`](docs/P0-实测报告.md) —— 能力矩阵、吞吐（1080p H.264→H.264 6.2x；4K HEVC→1080p H.264 5.7x）、取消与临时文件、元数据 identifier 写回矩阵
- 验证工具：[`Validation/P0/`](Validation/P0/) —— 命令行 `p0`（`swift run p0 all` 可复跑全部实测）
- 设计文档（唯一事实来源）：[`docs/设计文档.md`](docs/设计文档.md)

## 关键决策

- 技术路线：SwiftUI + AVFoundation（解封装/解码）+ VideoToolbox（硬件编码）+ AVAssetWriter（封装）；**不引入 FFmpeg**，0 第三方依赖
- 硬件加速是硬性要求：默认强制硬件编码器，没有则任务失败；**不静默回退软件**
- 支持边界（v1）：输入仅 MP4/MOV/M4V（MKV 后续版本再评估）；输出 H.264 / HEVC / ProRes（无 AV1/VP9）；HDR 检测后拒绝
- 架构为后续 MKV 留缝：引擎只依赖 `MediaSource` 抽象（轨道信息 + 按序 sample buffer）
- 电影元数据：勾选 → TMDB 匹配 → **人工确认后才能开始**；只写容器元数据，不烧录画面
- 落盘：原子输出，失败/取消不留半个文件；沙盒 + 安全书签；持久化用 Codable JSON + UserDefaults + Keychain（不引入 SwiftData）
- 界面：暗色优先、单一强调色、极简克制；科技感来自精度与留白，不靠霓虹/玻璃/粒子

## 环境

- 开发环境：Xcode 27.1 / Swift 6.4 / macOS 27.0.1 / Apple M1 Pro
- 最低系统 macOS 27.0（设计文档第 2 节；2026-10-17 由用户拍板，与开发机和最新 SDK 对齐）
- 硬件能力已在 M1 Pro 实测：Apple H.264 (HW) / Apple HEVC (HW) / AppleProResHW 422 系列可用；无 AV1/VP9 编码器

## P2 队列与预设（已完成，待走查）

已实现（源码在 `Chrysalis/Chrysalis/`）：

1. 队列：多文件串行执行、单任务取消/重试、清空已完成；10 文件批量已自动化验证。
2. 预设：4 个内置（兼容优先 / 均衡 / 小体积 / 高质量，参数见设计文档 §6.6）只读，「复制为自定义」后可编辑名称、视频编码（H.264/HEVC）、1080p 基准码率、音频码率；自定义存 `Application Support/Chrysalis/presets.json`，选择持久化。
3. HEVC 预设：均衡 / 高质量；输出 MP4（`hvc1`）已自动化验证。
4. 硬件能力矩阵：设置页只读展示各编码器的 HW 状态与名称（绿点/灰点）。
5. 输出目录安全书签（App Scope，`Chrysalis.entitlements`）+ 重启恢复队列：`queue.json`，活跃任务恢复为「已中断（可重试）」。
6. 添加 Sheet：文件列表 + 预设选择（「这些是电影」总开关随 P3 加入）。

走查步骤（手工）：

1. 预设页：点击卡片选中（accent 描边 +「默认」标签）；「复制为自定义」→ 改名/改编码/改码率 → 保存；自定义卡片可「编辑/删除」。
2. 拖入多个文件 → 添加 Sheet 选预设 → 添加 → 开始；点行尾 ↻ 可重试失败/取消/中断的任务。
3. 转码中途退出 App，重开：任务显示「已中断（可重试）」；输出文件夹应自动恢复。
4. 设置页查看硬件能力矩阵；检查器「输出」分区可见码率/预计大小。

## 目录

```
Chrysalis/
├── README.md          # 本文件
├── AGENTS.md          # 开发约定（开发 agent 执行说明）
├── docs/
│   ├── 设计文档.md     # 完整设计方案（唯一事实来源）
│   └── P0-实测报告.md  # P0 实测证据与结论
├── Chrysalis/         # Xcode 工程（Chrysalis.xcodeproj）+ App 源码
│   └── Chrysalis/     # App 目标源码：App / Core / Features / UI / Resources
└── Validation/
    └── P0/            # P0 验证工具（Swift 包，命令行 p0；产物 artifacts/ 不入库）
```

设计文档拷贝自 Obsidian 库 `20_项目/Mac视频转码工具/`；开发期间如有修订，先更新本仓库 `docs/设计文档.md` 并说明原因，事后回写库中。
