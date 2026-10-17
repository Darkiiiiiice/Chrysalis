@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// 单个 VideoToolbox 编码器条目。
struct EncoderInfo: Codable {
    var name: String
    var encoderID: String
    var isHardwareAccelerated: Bool
    var codecFourCC: String
    var codecName: String
}

/// 本机硬件能力快照（设计文档第 7 节）。
struct CapabilitiesReport: Codable {
    var encoders: [EncoderInfo]
    var hardwareDecodeSupported: [String: Bool]
    var notes: [String]

    func hardwareEncoder(forCodecFourCC fourCC: String) -> EncoderInfo? {
        encoders.first { $0.isHardwareAccelerated && $0.codecFourCC == fourCC }
    }
}

enum CapabilitiesProbe {
    static func probe() -> CapabilitiesReport {
        var notes: [String] = []
        var encoders: [EncoderInfo] = []

        var rawList: CFArray?
        let status = VTCopyVideoEncoderList(nil, &rawList)
        if status == noErr, let list = rawList as? [[String: Any]] {
            for entry in list {
                let name = entry[kVTVideoEncoderList_EncoderName as String] as? String ?? "(unknown)"
                let id = entry[kVTVideoEncoderList_EncoderID as String] as? String ?? "(unknown)"
                let hardware = entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false
                let codecRaw = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0
                encoders.append(EncoderInfo(
                    name: name,
                    encoderID: id,
                    isHardwareAccelerated: hardware,
                    codecFourCC: fourCCString(codecRaw),
                    codecName: codecFriendlyName(codecRaw)
                ))
            }
        } else {
            notes.append("VTCopyVideoEncoderList 失败，OSStatus=\(status)")
        }

        let decodeChecks: [(String, CMVideoCodecType)] = [
            ("H.264", kCMVideoCodecType_H264),
            ("HEVC", kCMVideoCodecType_HEVC),
            ("ProRes 422", kCMVideoCodecType_AppleProRes422),
            ("ProRes 422 HQ", kCMVideoCodecType_AppleProRes422HQ),
            ("ProRes 4444", kCMVideoCodecType_AppleProRes4444),
            ("AV1", kCMVideoCodecType_AV1),
            ("VP9", kCMVideoCodecType_VP9),
        ]
        var decode: [String: Bool] = [:]
        for (name, type) in decodeChecks {
            decode[name] = VTIsHardwareDecodeSupported(type)
        }

        if encoders.allSatisfy({ !$0.isHardwareAccelerated }) {
            notes.append("未发现任何硬件编码器：转码任务将在 preparing 阶段失败（硬性要求）。")
        }
        notes.append("AVAssetWriter 不暴露实际选中的编码器；命中硬件以“RequireHardwareAcceleratedVideoEncoder 标志被接受 + 实测速度/CPU”为证据。")

        return CapabilitiesReport(encoders: encoders, hardwareDecodeSupported: decode, notes: notes)
    }

    static func printReport(_ report: CapabilitiesReport) {
        Console.section("VideoToolbox 编码器列表（VTCopyVideoEncoderList）")
        let rows = report.encoders.map { encoder in
            [
                encoder.name,
                encoder.codecName,
                encoder.codecFourCC,
                encoder.isHardwareAccelerated ? "HW" : "SW",
                encoder.encoderID,
            ]
        }
        print(Fmt.table(rows, headers: ["名称", "编码", "FourCC", "类型", "EncoderID"]))

        Console.section("硬件解码支持（VTIsHardwareDecodeSupported）")
        for (name, supported) in report.hardwareDecodeSupported.sorted(by: { $0.key < $1.key }) {
            Console.kv(name, supported ? "支持" : "不支持")
        }

        for note in report.notes {
            Console.warn(note)
        }
    }
}

func fourCCString(_ value: UInt32) -> String {
    guard value != 0 else { return "(0)" }
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? String(bytes: bytes, encoding: .ascii) ?? "?" : String(format: "0x%08X", value)
}

func codecFriendlyName(_ value: UInt32) -> String {
    switch value {
    case kCMVideoCodecType_H264: return "H.264"
    case kCMVideoCodecType_HEVC: return "HEVC"
    case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422LT,
         kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422Proxy,
         kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
        return "ProRes"
    case kCMVideoCodecType_AV1: return "AV1"
    case kCMVideoCodecType_VP9: return "VP9"
    default: return fourCCString(value)
    }
}
