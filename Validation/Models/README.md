# P7.1 模型转换（Real-ESRGAN → Core ML）

本目录是 **开发期离线工具**，不属于 App target，不随 App 分发。

## 目的

P7.1 可行性 spike 回答三个问题：

1. `coremltools` 能否把 Real-ESRGAN 稳定转成 `.mlpackage`（fp16），数值误差是否可接受？
2. 转换后的模型在 Apple Silicon 上实际由哪个设备执行（ANE / GPU / CPU）？
3. tile（重叠 32px、羽化混合）处理 1080p→2x 的吞吐是否达到 §7.6 的「1080p30 ≥ 0.1x 实时」？

在三个问题都有实测结论前，不写 P7.2 及之后的集成代码。实测结论见 [`docs/P7-实测报告.md`](../../docs/P7-实测报告.md)：原生 compact 2x 在 M1 Pro 只有 0.060–0.074x；通用 4x + 半分辨率 + 352×288 tile 达到 0.146–0.149x（含预降采样/轻度 USM 估算 0.138x）。

## 模型与许可

- 模型族：**Real-ESRGAN**（<https://github.com/xinntao/Real-ESRGAN>），BSD-3-Clause。
- 本 spike 测试三个模型：
  - `RealESRGANv2-animevideo-xsx2.pth`：官方原生 2x、`SRVGGNetCompact`（约 0.6M 参数，2.3 MB），动画/插画调优，适合做原生 2x 质量对照。
  - `realesr-general-x4v3.pth`：通用 4x、`SRVGGNetCompact`（约 1.2M 参数，4.7 MB），本 spike 的推荐快路径（先 0.5x 预降采样，再 4x）。
  - `RealESRGAN_x2plus.pth`：`RRDBNet`（约 16.7M 参数，64 MB），用于观察大模型在 ANE 上的设备落点与吞吐差异。
- 权重下载地址：
  - <https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.3.0/RealESRGANv2-animevideo-xsx2.pth>
  - <https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth>
  - <https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth>
- `RealESRGAN_x2plus` 的 checkpoint `conv_first` 是 `[64,12,3,3]`：输入先做 2× `pixel_unshuffle`，主体在 1/2 分辨率；转换脚本已按此处理，`--arch rrdb --scale 2`。
- 权重文件本身也遵循 Real-ESRGAN 仓库的 BSD-3-Clause 许可；App 关于页需展示模型名、来源与许可（见设计文档 §7.6）。

## 产物策略（与 §13-14 一致）

- **入 git**：本 README、`convert_realesrgan.py`。
- **不入 git**：`.venv/`、`weights/`、`build/`、`artifacts/`（`.mlpackage` / `.mlmodelc` 均为本地生成）。
- App 打包前由本地脚本生成 `.mlmodelc` 并放入 App Resources；仓库不存二进制模型。

## 环境

需要 Python 3.11+（系统自带 3.9 不满足 coremltools 9 的要求）。本机使用 `uv`：

```sh
cd Validation/Models
uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python \
  --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
  coremltools torch pillow scipy
```

> 本机实测：coremltools 9.0 + torch 2.14.1 可用；coremltools 会提示 torch 版本未测试，但本模型的 trace/转换正常。

## 转换

```sh
cd Validation/Models
.venv/bin/python convert_realesrgan.py \
  --weights weights/RealESRGANv2-animevideo-xsx2.pth \
  --output build/AnimeVideoXS2.mlpackage \
  --tile 512 \
  --validate
```

脚本会：

- 从 checkpoint 自动识别 `SRVGGNetCompact` / `RRDBNet` 结构（层数、通道、放大倍数）；
- 以固定 `1×3×H×W` 输入 trace（`--tile` 为宽，`--tile-height` 为高；缺省正方形），转成 `mlprogram`、fp16，输入为 RGB 图像、输出为 RGB 图像（0–255）；
- 用同一张确定性测试图对比 PyTorch 与 Core ML 输出，打印平均/最大绝对误差；
- `--dump-reference` 额外写出 raw RGB 输入/参考输出，供 Swift 探针复核编译后的 `.mlmodelc`；
- 把来源、权重 SHA-256、转换参数写入模型元数据。

通用 4x 快路径（16:9 半分辨率推荐矩形 tile）：

```sh
.venv/bin/python convert_realesrgan.py \
  --weights weights/realesr-general-x4v3.pth \
  --output build/GeneralX4v3-t352x288.mlpackage \
  --tile 352 --tile-height 288 --validate \
  --dump-reference artifacts/reference-general-352x288
```

对照模型：

```sh
.venv/bin/python convert_realesrgan.py \
  --weights weights/RealESRGAN_x2plus.pth \
  --output build/RealESRGANx2plus.mlpackage \
  --tile 512 --arch rrdb --scale 2 --validate
```

## 编译与检查

```sh
xcrun coremlcompiler compile build/GeneralX4v3-t352x288.mlpackage build/
xcrun coremlcompiler generate --language swift build/GeneralX4v3-t352x288.mlpackage build/
```

编译产物为 `build/GeneralX4v3-t352x288.mlmodelc`。Swift 探针见 `Validation/P7/`：

```sh
cd ../P7
swift build -c release
.build/release/p7 verify \
  --model ../Models/build/GeneralX4v3-t352x288.mlmodelc \
  --tile 352 --tile-height 288 \
  --reference ../Models/artifacts/reference-general-352x288
.build/release/p7 bench \
  --model ../Models/build/GeneralX4v3-t352x288.mlmodelc \
  --width 960 --height 540 --tile 352 --tile-height 288 \
  --frames 5 --warmup 1
```

`bench` 的输入是已经预降采样到 960×540 的帧；`docs/P7-实测报告.md` 另有 `CILanczosScaleTransform` 与 `CIUnsharpMask` 的分项耗时。

## 结果

实测结果、设备落点、吞吐、内存峰值与画质对照统一记录在 [`docs/P7-实测报告.md`](../../docs/P7-实测报告.md)。要点：

- 转换：三个模型均成功；编译模型对 PyTorch 参考 PSNR 约 60 dB，最大差 1。
- 设备：`MLComputePlan` 估算 compact 99.5%、general 97.4% 工作量在 ANE；GPU-only 明显更慢。
- 吞吐：compact 原生 2x 最好 0.074x；general 4x + 960×540 + 352×288 为 0.146–0.149x；加预降采样/轻度 USM 估算 0.138x。
- 内存：所有路径 maxrss < 216 MB，远低于 1.5 GB。
- 画质：compact 更锐但过锐/偏色；general 自然但偏软，USM 可补感知锐度；真实片源需 P7.4 复核。

画质对照图在 `artifacts/quality/`（gitignored），包括 `display-vineyard.png`、`display-trees.png`、`display-general-sharp60.png`、`display-compact-light.png`。
