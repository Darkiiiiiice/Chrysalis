# 蝉蜕（Chrysalis）

macOS 上的本地视频转码工具：拖入视频，批量转码为 H.264 / HEVC / ProRes，默认走 Apple 硬件媒体引擎（VideoToolbox），速度优先、CPU 占用低；可选从 TMDB 获取电影元数据，人工确认后写入 MP4/MOV 容器。纯 Swift + SwiftUI，零第三方依赖。

> 「蝉蜕」取意「金蝉脱壳」——转码即蜕变：旧壳（容器）留在身后，影像本体无损，飞向新形。英文名「Chrysalis」是蛹壳——蜕变发生的静默容器；原文件保留、输出原子落盘，正合其意。

## 状态

**P0 技术验证已完成**（2026-10-17，全部通过标准达成）。**P1 单文件 MVP 代码已就绪，待手工验收**。

- Xcode 工程：[`Chrysalis/Chrysalis.xcodeproj`](Chrysalis/Chrysalis.xcodeproj) —— 仅 macOS 14.0+、Swift 6（严格并发）、App Sandbox、Hardened Runtime
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
- 最低系统 macOS 14.0（见设计文档第 2 节；第 13 节列为待确认项）
- 硬件能力已在 M1 Pro 实测：Apple H.264 (HW) / Apple HEVC (HW) / AppleProResHW 422 系列可用；无 AV1/VP9 编码器

## P1 单文件 MVP（代码已就绪，待验收）

已实现（源码在 `Chrysalis/Chrysalis/`）：

1. 工程：仅 macOS 14.0+、Swift 6 语言模式、App Sandbox（用户选择文件读写）、Hardened Runtime；无 iOS 残留配置。
2. 设计 Token：Asset Catalog 12 个颜色（Any/Dark 两套，视图零硬编码 hex）；字体、间距、圆角、动效在 `UI/Theme.swift`；24px 拖放网格。
3. 两栏 `NavigationSplitView`（侧边栏 208 + 详情）+ 原生 toolbar（添加 / 开始 / 取消 / 输出文件夹 / 检查器）+ `⌘I` 可隐藏检查器（304px）。
4. 拖放与文件选择（MP4/MOV/M4V；其他类型忽略并轻提示）、媒体信息预检（容器/轨道/尺寸/帧率/码率/音频/HDR/硬件解码）。
5. 单文件 H.264 + AAC 输出 MP4，强制硬件编码（`AVVideoEncoderSpecificationKey` + `RequireHardwareAcceleratedVideoEncoder`）；音频解码为 LPCM 后统一编码 AAC-LC 192 kbps。
6. 进度/速度/ETA（EMA，UI ≤10Hz）、取消（无临时文件残留）、原子落盘（`.chrysalis-*.tmp` → 最终名，重名加 `-1`）、基础错误提示（inline banner + 检查器「错误」区，可复制详情）。

验收步骤（手工）：

1. Xcode 打开 `Chrysalis/Chrysalis.xcodeproj` 运行，或直接 `open` 构建产物。
2. 工具栏「输出文件夹」选一个目录 → 拖入一个 MP4 → 点「开始」。
3. 预期：出现 HW 徽章与速度/剩余时间；完成后输出可播放；行尾显示输出大小。
4. 取消验证：转码中途点行尾 ✕（hover 出现）或 `⌘.`；输出来源目录里不应留下 `.chrysalis-*.tmp`。
5. 暗色/浅色切换检查界面是否符合 Token（无硬编码颜色）。

> 已知 P1 边界：预设固定为「兼容优先」（P2 起可切换）；历史/设置/预设页为占位；软件回退开关不提供（保持硬性硬件要求）。

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
