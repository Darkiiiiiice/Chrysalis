#!/usr/bin/env python3
"""把 Real-ESRGAN 权重转换成 Core ML（mlprogram / fp16 / 固定 tile 输入）。

仅开发期使用，不进入 App。支持两种官方结构：

- SRVGGNetCompact（2x 动画模型 / 4x 通用模型）
- RRDBNet（RealESRGAN_x2plus）

输入输出都是 Core ML 图像类型：
- 输入：RGB，1x3xHxW，scale=1/255（0–255 → 0–1）
- 输出：RGB，scale*H x scale*W，模型内部已乘 255 并 clamp（Core ML 图像输出只接受 scale=1）

`--tile` 是宽度，`--tile-height` 缺省时与宽度相同；16:9 半分辨率快路径用 352×288。
用法见 README.md。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


# ---------------------------------------------------------------------------
# 网络结构（与 BasicSR / Real-ESRGAN 保持一致，去掉训练相关代码）
# ---------------------------------------------------------------------------


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN 的轻量视频超分结构。"""

    def __init__(
        self,
        num_in_ch: int = 3,
        num_out_ch: int = 3,
        num_feat: int = 64,
        num_conv: int = 16,
        upscale: int = 4,
        act_type: str = "prelu",
    ) -> None:
        super().__init__()
        self.upscale = upscale
        body: list[nn.Module] = [nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)]
        body.append(self._act(act_type, num_feat))
        for _ in range(num_conv):
            body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            body.append(self._act(act_type, num_feat))
        body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    @staticmethod
    def _act(act_type: str, num_feat: int) -> nn.Module:
        if act_type == "relu":
            return nn.ReLU(inplace=True)
        if act_type == "prelu":
            return nn.PReLU(num_parameters=num_feat)
        if act_type == "leakyrelu":
            return nn.LeakyReLU(negative_slope=0.1, inplace=True)
        raise ValueError(f"不支持的激活函数：{act_type}")

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out + base


class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat: int = 64, num_grow_ch: int = 32) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat: int, num_grow_ch: int = 32) -> None:
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    """官方 RRDBNet。

    RealESRGAN_x2plus 的 checkpoint 在 conv_first 之前做 2× pixel_unshuffle
    （3 通道 → 12 通道、空间减半），网络主体在 1/2 分辨率上计算，最后两次
    2× 上采样净得 2× 输出。x4plus 则是 3 通道输入 + 两次 2× 上采样。
    """

    def __init__(
        self,
        num_in_ch: int = 3,
        num_out_ch: int = 3,
        num_feat: int = 64,
        num_block: int = 23,
        num_grow_ch: int = 32,
        scale: int = 2,
        unshuffle: int = 1,
    ) -> None:
        super().__init__()
        self.scale = scale
        self.unshuffle = unshuffle
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(
            *[RRDB(num_feat, num_grow_ch) for _ in range(num_block)]
        )
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.unshuffle > 1:
            x = F.pixel_unshuffle(x, self.unshuffle)
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(
            self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest"))
        )
        feat = self.lrelu(
            self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest"))
        )
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


class ImageOutput(nn.Module):
    """把模型输出整理成 Core ML 图像输出所需的 0–255 浮点值。"""

    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return torch.clamp(self.model(x), 0.0, 1.0) * 255.0


# ---------------------------------------------------------------------------
# 权重识别
# ---------------------------------------------------------------------------


def load_state_dict(path: Path) -> dict[str, torch.Tensor]:
    checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    if not isinstance(checkpoint, dict):
        raise ValueError(f"{path} 不是 state_dict")
    for key in ("params_ema", "params"):
        if key in checkpoint and isinstance(checkpoint[key], dict):
            return checkpoint[key]
    if all(isinstance(v, torch.Tensor) for v in checkpoint.values()):
        return checkpoint
    raise ValueError(f"无法在 {path} 中识别权重字典：{list(checkpoint)[:8]}")


def build_model(state: dict[str, torch.Tensor], arch: str, scale: int | None):
    if arch == "auto":
        if "conv_first.weight" in state:
            arch = "rrdb"
        elif "body.0.weight" in state:
            arch = "srvgg"
        else:
            raise ValueError("无法自动识别网络结构，请用 --arch 指定")

    if arch == "srvgg":
        num_feat = state["body.0.weight"].shape[0]
        body_indices = sorted(
            int(key.split(".")[1])
            for key in state
            if key.startswith("body.") and key.endswith(".weight") and key.count(".") == 2
        )
        final_index = body_indices[-1]
        num_conv = (final_index - 2) // 2
        out_channels = state[f"body.{final_index}.weight"].shape[0]
        inferred_scale = int(round(math.sqrt(out_channels / 3)))
        if inferred_scale * inferred_scale * 3 != out_channels:
            raise ValueError(f"无法从输出通道 {out_channels} 推断放大倍数")
        if scale is not None and scale != inferred_scale:
            raise ValueError(f"权重是 {inferred_scale}x，但 --scale 指定 {scale}")
        use_prelu = "body.1.weight" in state
        act_type = "prelu" if use_prelu else "relu"
        if use_prelu:
            prelu_channels = state["body.1.weight"].shape[0]
            if prelu_channels not in (1, num_feat):
                raise ValueError(f"意外的 PReLU 通道数：{prelu_channels}")
        model = SRVGGNetCompact(
            num_feat=num_feat,
            num_conv=num_conv,
            upscale=inferred_scale,
            act_type=act_type,
        )
        if use_prelu:
            # BasicSR 的 PReLU 是逐通道参数；如果权重只有 1 个通道，沿用默认实现。
            if state["body.1.weight"].shape[0] == 1:
                _replace_prelu(model, 1)
        return model, inferred_scale, {
            "arch": "SRVGGNetCompact",
            "num_feat": num_feat,
            "num_conv": num_conv,
            "act_type": act_type,
        }

    if arch == "rrdb":
        if scale is None:
            raise ValueError("RRDBNet 的放大倍数无法从权重推断，请用 --scale 指定")
        num_in_ch = state["conv_first.weight"].shape[1]
        num_feat = state["conv_first.weight"].shape[0]
        num_grow_ch = state["body.0.rdb1.conv1.weight"].shape[0]
        num_block = len(
            {key.split(".")[1] for key in state if key.startswith("body.") and ".rdb1.conv1.weight" in key}
        )
        # x2plus：3 通道输入经 2× pixel_unshuffle 变成 12 通道，主体分辨率减半。
        unshuffle = 2 if scale == 2 and num_in_ch == 12 else 1
        if unshuffle == 1 and num_in_ch != 3:
            raise ValueError(f"RRDBNet 输入通道 {num_in_ch} 与 scale={scale} 不匹配")
        model = RRDBNet(
            num_in_ch=num_in_ch,
            num_feat=num_feat,
            num_block=num_block,
            num_grow_ch=num_grow_ch,
            scale=scale,
            unshuffle=unshuffle,
        )
        return model, scale, {
            "arch": "RRDBNet",
            "num_feat": num_feat,
            "num_block": num_block,
            "num_grow_ch": num_grow_ch,
            "num_in_ch": num_in_ch,
            "unshuffle": unshuffle,
        }

    raise ValueError(f"未知结构：{arch}")


def _replace_prelu(model: SRVGGNetCompact, channels: int) -> None:
    for index, layer in enumerate(model.body):
        if isinstance(layer, nn.PReLU) and layer.num_parameters != channels:
            model.body[index] = nn.PReLU(num_parameters=channels)


# ---------------------------------------------------------------------------
# 验证
# ---------------------------------------------------------------------------


def make_validation_image(
    size: int,
    seed: int = 20261021,
    height: int | None = None,
) -> np.ndarray:
    """生成确定性的渐变+噪声验证图；height 缺省时与 size 相同（正方形）。"""
    height = size if height is None else height
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:height, 0:size]
    base = np.stack(
        [
            (x / max(size - 1, 1) * 255.0),
            (y / max(height - 1, 1) * 255.0),
            ((x / max(size - 1, 1) + y / max(height - 1, 1)) / 2.0 * 255.0),
        ],
        axis=-1,
    )
    noise = rng.normal(0.0, 12.0, base.shape)
    return np.clip(base + noise, 0, 255).astype(np.uint8)


def validate(
    torch_model: nn.Module,
    coreml_model,
    image: np.ndarray,
    tag: str,
    dump_dir: Path | None = None,
) -> dict[str, float]:
    from PIL import Image

    tensor = (
        torch.from_numpy(image).permute(2, 0, 1).unsqueeze(0).float() / 255.0
    )
    with torch.no_grad():
        reference = (
            torch.clamp(torch_model(tensor), 0.0, 1.0) * 255.0
        ).squeeze(0).permute(1, 2, 0).numpy()

    prediction = np.asarray(
        coreml_model.predict({"frame": Image.fromarray(image)})["out"]
    )[..., :3].astype(np.float32)

    if prediction.shape != reference.shape:
        raise RuntimeError(
            f"{tag} 输出形状不一致：Core ML {prediction.shape} vs PyTorch {reference.shape}"
        )

    diff = np.abs(prediction - reference)
    mse = float(np.mean(diff * diff))
    psnr = float("inf") if mse == 0 else float(10.0 * math.log10(255.0 * 255.0 / mse))
    result = {
        "mean_abs": float(np.mean(diff)),
        "p95_abs": float(np.percentile(diff, 95)),
        "max_abs": float(np.max(diff)),
        "psnr_db": psnr,
        "output_min": float(prediction.min()),
        "output_max": float(prediction.max()),
    }
    print(
        f"[验证] {tag}: mean={result['mean_abs']:.3f} p95={result['p95_abs']:.3f} "
        f"max={result['max_abs']:.1f} PSNR={result['psnr_db']:.2f} dB "
        f"range=[{result['output_min']:.0f}, {result['output_max']:.0f}]"
    )

    if dump_dir is not None:
        dump_dir.mkdir(parents=True, exist_ok=True)
        image.astype(np.uint8).tofile(dump_dir / "validation-input.rgb")
        np.clip(np.rint(reference), 0, 255).astype(np.uint8).tofile(
            dump_dir / "validation-reference.rgb"
        )
        (dump_dir / "validation.json").write_text(
            json.dumps(
                {
                    "input_width": int(image.shape[1]),
                    "input_height": int(image.shape[0]),
                    "scale": int(prediction.shape[1] // image.shape[1]),
                    "channel_order": "RGB",
                    **result,
                },
                indent=2,
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        print(f"[验证] 参考数据已写入 {dump_dir}")

    return result


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tile", type=int, default=512, help="输入 tile 宽度，默认 512")
    parser.add_argument(
        "--tile-height",
        type=int,
        default=None,
        help="输入 tile 高度；缺省与 --tile 相同（正方形）",
    )
    parser.add_argument(
        "--arch", choices=("auto", "srvgg", "rrdb"), default="auto"
    )
    parser.add_argument("--scale", type=int, choices=(2, 3, 4), default=None)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument(
        "--dump-reference",
        type=Path,
        default=None,
        help="把验证输入与 PyTorch 参考输出写成 raw RGB，供 Swift 探针复核",
    )
    parser.add_argument(
        "--precision", choices=("fp16", "fp32"), default="fp16"
    )
    args = parser.parse_args()

    if not args.weights.is_file():
        raise FileNotFoundError(args.weights)

    state = load_state_dict(args.weights)
    model, scale, info = build_model(state, args.arch, args.scale)
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise RuntimeError(f"权重与结构不匹配：missing={missing[:8]} unexpected={unexpected[:8]}")
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)

    tile_height = args.tile_height or args.tile
    if args.tile <= 0 or tile_height <= 0:
        raise ValueError("tile 宽高必须为正数")

    wrapper = ImageOutput(model).eval()
    example = torch.rand(1, 3, tile_height, args.tile)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)
        traced = torch.jit.freeze(traced)

    import coremltools as ct

    precision = (
        ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    )
    coreml_model = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="frame",
                shape=(1, 3, tile_height, args.tile),
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[
            ct.ImageType(
                name="out",
                scale=1.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS15,
    )

    weights_hash = sha256(args.weights)
    coreml_model.author = "Xintao Wang et al. / Real-ESRGAN contributors"
    coreml_model.license = "BSD-3-Clause"
    coreml_model.short_description = (
        f"Real-ESRGAN {info['arch']} {scale}x upscaler, fixed {args.tile}x{tile_height} tile"
    )
    coreml_model.user_defined_metadata.update(
        {
            "source": "https://github.com/xinntao/Real-ESRGAN",
            "weights_file": args.weights.name,
            "weights_sha256": weights_hash,
            "architecture": info["arch"],
            "scale": str(scale),
            "tile": f"{args.tile}x{tile_height}",
            "precision": args.precision,
            "io": "image RGB 0-255 in / image RGB 0-255 out",
            "conversion_script": "Validation/Models/convert_realesrgan.py",
            "info": json.dumps(info, ensure_ascii=False, sort_keys=True),
        }
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(args.output))
    print(f"[完成] 已保存 {args.output}")
    print(
        f"        结构 {info} / {scale}x / 输入 {args.tile}x{tile_height} / {args.precision}"
    )

    if args.validate or args.dump_reference is not None:
        image_width = min(args.tile, 512)
        image_height = min(tile_height, 512)
        # 验证模型与正式模型输入尺寸一致才能复用；否则单独 trace 一个小模型。
        if image_width != args.tile or image_height != tile_height:
            print("[跳过] 验证图尺寸与 tile 不一致")
        else:
            image = make_validation_image(image_width, height=image_height)
            validate(
                model,
                coreml_model,
                image,
                args.weights.name,
                dump_dir=args.dump_reference,
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
