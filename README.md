# 蝉蜕（Chrysalis）

macOS 上的本地视频转码工具：拖入视频，批量转码为 H.264 / HEVC / ProRes，默认走 Apple 硬件媒体引擎（VideoToolbox），速度优先、CPU 占用低；可选从 TMDB 获取电影元数据，人工确认后写入 MP4/MOV 容器。纯 Swift + SwiftUI，零第三方依赖。

> 「蝉蜕」取意「金蝉脱壳」——转码即蜕变：旧壳（容器）留在身后，影像本体无损，飞向新形。英文名「Chrysalis」是蛹壳——蜕变发生的静默容器；原文件保留、输出原子落盘，正合其意。

## 状态

规划完成，等待开发。设计文档（唯一事实来源）：

- [`docs/设计文档.md`](docs/设计文档.md) —— 完整方案：目标与非目标 / 支持矩阵 / 技术路线 / 架构与状态机 / 转码管线 / 硬件加速设计（第 7 节）/ TMDB 电影元数据（第 7.5 节）/ UI 设计系统（第 8 节）/ 里程碑（P0–P6）/ 验收与测试 / 风险表 / 待确认项

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

## 下一步（P0 技术验证）

1. 创建 Xcode 工程（App 模板，产品名 `Chrysalis`）：App Sandbox + `network.client`、Hardened Runtime
2. 用 `AVAssetReader` + `AVAssetWriter` 转 H.264，强制硬件编码器（`RequireHardwareAcceleratedVideoEncoder`）
3. 同样跑 HEVC 与 ProRes，记录速度、CPU、内存
4. 验证进度、取消、临时文件清理
5. 用 `AVAssetWriter.metadata` 往 MP4/MOV 写标题/年份/简介/类型，再用 `AVURLAsset` 读回，记录哪些 identifier 真正生效
6. 输出实测数据：1080p / 4K、H.264 / HEVC / ProRes 的 x 倍速

通过标准：M1 Pro 上 1080p H.264 → H.264 ≥ 4x 实时；4K HEVC → 1080p H.264 ≥ 1x 实时；取消无残留。详见设计文档「P0 技术验证」。

## 目录

```
Chrysalis/
├── README.md          # 本文件
├── AGENTS.md          # 开发约定（开发 agent 执行说明）
└── docs/
    └── 设计文档.md     # 完整设计方案（拷贝自 Obsidian 库）
```

设计文档拷贝自 Obsidian 库 `20_项目/Mac视频转码工具/`；开发期间如有修订，先更新本仓库 `docs/设计文档.md` 并说明原因，事后回写库中。
