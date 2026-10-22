import AVFoundation
import Foundation
import Speech

// MARK: - 语音转字幕（设计文档 §7.13，灵感 9）
// 系统 Speech framework 强制设备端识别：完全离线，零依赖零模型；
// 识别结果人工预览确认后才落盘，「网络仅 TMDB」约束不变。

/// 一条识别段（时间戳 + 文本）。
struct RecognizedSegment: Sendable {
    var start: Double
    var duration: Double
    var text: String
}

/// 识别回调与 continuation 之间的一次性状态（线程安全；保证只 resume 一次）。
private final class RecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    var continuation: CheckedContinuation<[RecognizedSegment], Error>?
    var collected: [RecognizedSegment]?
    var task: SFSpeechRecognitionTask?

    func resume(returning segments: [RecognizedSegment]) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: segments)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        task?.finish()
        continuation?.resume(throwing: error)
    }
}

/// 设备端语音转字幕服务。
enum SpeechTranscriber {
    /// 设备端识别支持的 locale 列表（supportedLocales ∩ on-device 支持）。
    static func supportedLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales().compactMap { locale in
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                  recognizer.supportsOnDeviceRecognition
            else { return nil }
            return locale
        }
    }

    /// locale 的展示名（本地化语言名，如「中文（普通话 - 中国大陆）」）。
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// 对视频文件执行设备端语音识别，返回字幕文档（内存态，人工确认后导出）。
    ///
    /// - Parameters:
    ///   - url: 视频（或音频）文件；系统自行提取音轨。
    ///   - locale: 识别语言（必须来自 `supportedLocales()`，否则明确拒绝）。
    ///   - audioDurationSeconds: 音频时长（进度口径；0 表示未知，进度恒 0）。
    static func transcribe(
        url: URL,
        locale: Locale,
        audioDurationSeconds: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SubtitleDocument {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable(locale.identifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // 硬性要求设备端识别（完全离线；设计文档 §7.13）
        request.requiresOnDeviceRecognition = true

        let segments: [RecognizedSegment] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RecognizedSegment], Error>) in
            let box = RecognitionBox()
            box.continuation = continuation
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    box.collected = result.bestTranscription.segments.map { segment in
                        RecognizedSegment(start: segment.timestamp, duration: segment.duration, text: segment.substring)
                    }
                    if let progress, audioDurationSeconds > 0, let last = box.collected?.last {
                        progress(min(last.start / audioDurationSeconds, 1.0))
                    }
                    if result.isFinal {
                        box.resume(returning: box.collected ?? [])
                    }
                }
                if let error {
                    box.resume(throwing: error)
                }
            }
            box.task = task
        }

        return Self.makeDocument(from: segments.map { (start: $0.start, duration: $0.duration, text: $0.text) })
    }

    // MARK: - 纯函数（harness 可测）

    /// 识别段 → 字幕 cue：空文本与 < 0.2s 片段过滤、时间排序、顺序 lineIndex。
    static func makeCues(
        from segments: [(start: Double, duration: Double, text: String)]
    ) -> [SubtitleCue] {
        let valid = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.duration >= 0.2 }
            .sorted { $0.start < $1.start }
        return valid.enumerated().map { index, segment in
            SubtitleCue(
                lineIndex: index,
                start: segment.start,
                end: segment.start + segment.duration,
                lines: [segment.text.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    /// 识别段 → 字幕文档（SRT 口径的内存态文档）。
    static func makeDocument(
        from segments: [(start: Double, duration: Double, text: String)]
    ) -> SubtitleDocument {
        SubtitleDocument(format: .srt, rawLines: [], cues: makeCues(from: segments))
    }

    enum TranscriptionError: LocalizedError, Sendable {
        case notAuthorized
        case localeUnsupported(String)
        case onDeviceUnavailable(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "语音识别权限未授权：请在系统设置 → 隐私与安全性 → 语音识别中允许蝉蜕。"
            case .localeUnsupported(let identifier):
                "当前系统不支持「\(identifier)」的语音识别。"
            case .onDeviceUnavailable(let identifier):
                "「\(identifier)」不支持设备端识别（需要联网发送音频），蝉蜕不使用该模式。"
            case .engineFailed(let message):
                "语音识别失败：\(message)"
            }
        }
    }
}

// MARK: - 字幕生成器

/// 识别 cue → SRT / ASS 文本（设计文档 §7.13）。
enum SubtitleGenerator {
    /// 生成 SRT 文本。
    static func srt(cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))")
            lines.append(contentsOf: cue.lines)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 生成 ASS 文本（默认样式模板 + Dialogue 行）。
    static func ass(cues: [SubtitleCue], playResX: Double = 1920, playResY: Double = 1080) -> String {
        var lines: [String] = []
        lines.append("[Script Info]")
        lines.append("ScriptType: v4.00+")
        lines.append("PlayResX: \(Int(playResX))")
        lines.append("PlayResY: \(Int(playResY))")
        lines.append("")
        lines.append("[V4+ Styles]")
        lines.append("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
        lines.append("Style: Default,Arial,54,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,60,60,40,1")
        lines.append("")
        lines.append("[Events]")
        lines.append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
        for cue in cues {
            let text = cue.lines.joined(separator: "\\N")
            lines.append(
                "Dialogue: 0,\(assTimestamp(cue.start)),\(assTimestamp(cue.end)),Default,,0,0,0,,\(text)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// SRT 时间戳：`HH:MM:SS,mmm`。
    static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let total = Int((clamped * 1000).rounded())
        let hours = total / 3_600_000
        let minutes = (total % 3_600_000) / 60_000
        let secs = (total % 60_000) / 1000
        let millis = total % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// ASS 时间戳：`H:MM:SS.cc`（百分之一秒）。
    static func assTimestamp(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let total = Int((clamped * 100).rounded())
        let hours = total / 360_000
        let minutes = (total % 360_000) / 6_000
        let secs = (total % 6_000) / 100
        let centis = total % 100
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centis)
    }
}
