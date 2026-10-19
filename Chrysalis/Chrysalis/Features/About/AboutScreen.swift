import AppKit
import SwiftUI

/// 关于窗口（P6.3）：应用名、版本、定位、技术栈与 TMDB 固定署名。
struct AboutScreen: View {
    /// 版本行，如「1.0 (1)」。
    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.s3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            VStack(spacing: Theme.Spacing.s1) {
                Text("蝉蜕 Chrysalis")
                    .font(Theme.TextStyle.display)
                    .foregroundStyle(Theme.textPrimary)
                Text("版本 \(versionLine)")
                    .font(Theme.TextStyle.numeric)
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("macOS 本地视频转码工具：更快、更兼容、更小。")
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 4) {
                Text("纯 Swift / SwiftUI · AVFoundation / VideoToolbox")
                Text("零第三方依赖 · 默认硬件加速")
            }
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)

            Divider()

            VStack(spacing: 4) {
                Text("© 2026 蝉蜕 Chrysalis")
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .multilineTextAlignment(.center)
            }
            .font(Theme.TextStyle.label)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.s5)
        .frame(width: 360)
        .background(Theme.bg)
    }
}
