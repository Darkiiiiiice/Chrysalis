@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// 单个 VideoToolbox 编码器条目（`VTCopyVideoEncoderList` 的整理结果）。
struct EncoderInfo: Sendable, Equatable {
    var name: String
    var encoderID: String
    var isHardwareAccelerated: Bool
    var codecFourCC: String
    var codec: VideoCodec?
}

/// 本机硬件能力快照（启动时探测一次；设计文档 §7 能力检测）。
struct HardwareCapabilities: Sendable, Equatable {
    var encoders: [EncoderInfo]
    var h264HardwareDecode: Bool

    init(encoders: [EncoderInfo] = [], h264HardwareDecode: Bool = false) {
        self.encoders = encoders
        self.h264HardwareDecode = h264HardwareDecode
    }

    /// 目标编码的硬件编码器；ProRes 家族共用硬件编码器。
    func hardwareEncoder(for codec: VideoCodec) -> EncoderInfo? {
        if let exact = encoders.first(where: { $0.isHardwareAccelerated && $0.codec == codec }) {
            return exact
        }
        if codec.isProRes {
            return encoders.first { $0.isHardwareAccelerated && ($0.codec?.isProRes ?? false) }
        }
        return nil
    }

    var isReady: Bool { hardwareEncoder(for: .h264) != nil }

    /// 侧边栏底部摘要，如 `HW · H.264 / HEVC / ProRes`。
    var summaryText: String {
        let labels: [String] = [VideoCodec.h264, .hevc, .proRes422]
            .filter { hardwareEncoder(for: $0) != nil }
            .map(\.familyLabel)
        guard !labels.isEmpty else { return "未检测到硬件编码器" }
        return "HW · " + labels.joined(separator: " / ")
    }

    var unavailableReason: String? {
        isReady ? nil : "本机没有可用的硬件编码器，转码任务无法开始"
    }
}

/// VideoToolbox 能力探测。
enum VideoToolboxCapabilities {
    /// 探测一次，返回本机能力快照（纯函数，可在任意线程调用）。
    static func probe() -> HardwareCapabilities {
        var encoders: [EncoderInfo] = []

        var rawList: CFArray?
        if VTCopyVideoEncoderList(nil, &rawList) == noErr, let list = rawList as? [[String: Any]] {
            for entry in list {
                let name = entry[kVTVideoEncoderList_EncoderName as String] as? String ?? "（未命名）"
                let encoderID = entry[kVTVideoEncoderList_EncoderID as String] as? String ?? ""
                let isHardware = entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false
                let codecRaw = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0
                let fourCC = fourCCString(codecRaw)
                encoders.append(EncoderInfo(
                    name: name,
                    encoderID: encoderID,
                    isHardwareAccelerated: isHardware,
                    codecFourCC: fourCC,
                    codec: VideoCodec(fourCC: fourCC)
                ))
            }
        }

        return HardwareCapabilities(
            encoders: encoders,
            h264HardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        )
    }

    /// fourCC 数值转可读字符串（`avc1`）。
    static func fourCCString(_ value: UInt32) -> String {
        guard value != 0 else { return "(0)" }
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? (String(bytes: bytes, encoding: .ascii) ?? "?") : String(format: "0x%08X", value)
    }
}
