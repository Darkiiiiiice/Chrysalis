@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import VideoToolbox

/// 预检（设计文档 §6.1）：读元数据、判断是否可转。
enum MediaInspector {
    /// v1 允许的输入容器（不加扩展支持列表，见设计文档 §3）。
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 读取媒体信息；不可转的文件抛出 `TranscodeEngineError`（人话原因）。
    static func inspect(url: URL) async throws -> MediaInfo {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw TranscodeEngineError.unsupportedContainer(ext.isEmpty ? "(无扩展名)" : ext)
        }

        let asset = AVURLAsset(url: url)

        let loaded: (playable: Bool, protected: Bool, duration: CMTime, tracks: [AVAssetTrack])
        do {
            loaded = (
                try await asset.load(.isPlayable),
                try await asset.load(.hasProtectedContent),
                try await asset.load(.duration),
                try await asset.load(.tracks)
            )
        } catch {
            throw TranscodeEngineError.notPlayable
        }

        guard loaded.playable else { throw TranscodeEngineError.notPlayable }
        guard !loaded.protected else { throw TranscodeEngineError.protectedContent }
        guard let videoTrack = loaded.tracks.first(where: { $0.mediaType == .video }) else {
            throw TranscodeEngineError.noVideoTrack
        }

        // MARK: 视频轨
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let nominalFPS = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)
        let estimatedRate = Double((try? await videoTrack.load(.estimatedDataRate)) ?? 0)
        let videoFormat = (try? await videoTrack.load(.formatDescriptions))?.first

        let oriented = VideoGeometry.orientedSize(naturalSize: naturalSize, preferredTransform: transform)
        let videoFourCCValue = videoFormat.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let videoFourCC = VideoToolboxCapabilities.fourCCString(videoFourCCValue)
        let hardwareDecode = videoFourCCValue != 0 ? VTIsHardwareDecodeSupported(videoFourCCValue) : false
        let (isHDR, hdrLabel) = detectHDR(format: videoFormat)

        let video = VideoStreamInfo(
            codecFourCC: videoFourCC,
            codecName: videoCodecDisplayName(fourCC: videoFourCC),
            displayWidth: Int(oriented.width.rounded()),
            displayHeight: Int(oriented.height.rounded()),
            frameRate: nominalFPS > 0 ? nominalFPS : 30,
            bitrate: estimatedRate > 0 ? Int(estimatedRate) : nil,
            hardwareDecodeSupported: hardwareDecode
        )

        // MARK: 音频轨（可选）
        var audio: AudioStreamInfo?
        if let audioTrack = loaded.tracks.first(where: { $0.mediaType == .audio }) {
            let audioFormat = (try? await audioTrack.load(.formatDescriptions))?.first
            let audioRate = Double((try? await audioTrack.load(.estimatedDataRate)) ?? 0)

            var channels = 0
            var sampleRate: Double = 0
            if let audioFormat,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
                sampleRate = asbd.pointee.mSampleRate
            }
            let formatID = audioFormat.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0

            audio = AudioStreamInfo(
                codecFourCC: formatID != 0 ? VideoToolboxCapabilities.fourCCString(formatID) : "",
                codecName: audioCodecDisplayName(formatID: formatID),
                channelCount: channels,
                sampleRate: sampleRate,
                bitrate: audioRate > 0 ? Int(audioRate) : nil
            )
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let durationSeconds = loaded.duration.seconds

        return MediaInfo(
            containerLabel: containerLabel(forExtension: ext),
            fileSizeBytes: Int64(fileSize),
            durationSeconds: durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 0,
            video: video,
            audio: audio,
            isHDR: isHDR,
            hdrLabel: hdrLabel,
            hasProtectedContent: false
        )
    }

    /// 拒绝转码的预检结论；nil 表示可以进入队列（设计文档 §6.1 第 6/7 条）。
    static func blockingReason(for info: MediaInfo) -> String? {
        if info.isHDR {
            return TranscodeEngineError.hdrUnsupported(info.hdrLabel ?? "HDR").errorDescription
        }
        if let video = info.video, !video.hardwareDecodeSupported {
            return TranscodeEngineError.hardwareDecodeUnavailable(video.codecName).errorDescription
        }
        return nil
    }

    // MARK: - 内部工具

    /// HDR 检测：PQ（HDR10）与 HLG（设计文档 §6.1 第 6 条：v1 拒绝）。
    static func detectHDR(format: CMFormatDescription?) -> (isHDR: Bool, label: String?) {
        guard let format,
              let transfer = CMFormatDescriptionGetExtension(
                format,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction
              ) as? String
        else { return (false, nil) }

        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
            return (true, "HDR10（PQ）")
        }
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
            return (true, "HLG")
        }
        return (false, nil)
    }

    static func containerLabel(forExtension ext: String) -> String {
        switch ext {
        case "mp4": "MP4"
        case "m4v": "M4V"
        case "mov": "QuickTime"
        default: ext.uppercased()
        }
    }

    static func videoCodecDisplayName(fourCC: String) -> String {
        if let codec = VideoCodec(fourCC: fourCC) { return codec.displayName }
        switch fourCC {
        case "jpeg": return "Motion JPEG"
        case "ap4x": return "ProRes 4444 XQ"
        default: return fourCC
        }
    }

    static func audioCodecDisplayName(formatID: FourCharCode) -> String {
        switch formatID {
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEG4AAC_HE: "AAC HE"
        case kAudioFormatMPEG4AAC_HE_V2: "AAC HE v2"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatOpus: "Opus"
        default: formatID != 0 ? VideoToolboxCapabilities.fourCCString(formatID) : "—"
        }
    }
}
