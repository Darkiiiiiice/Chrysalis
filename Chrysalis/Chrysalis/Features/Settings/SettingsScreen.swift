import SwiftUI

/// 设置页（设计文档 §8.6）：TMDB 凭据与元数据缓存 + 「硬件」分组（能力矩阵只读）。
struct SettingsScreen: View {
    @Environment(QueueStore.self) private var store

    @State private var credentialInput = ""
    @State private var validationMessage: String?
    @State private var isSavingCredential = false
    @State private var isTestingProxy = false
    @State private var proxyTestMessage: String?
    @State private var proxyTestSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                    tmdbSection
                    proxySection
                    hardwareSection
                }
                .padding(Theme.Size.contentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.bg)
        .onChange(of: store.proxySettings) {
            proxyTestMessage = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s1) {
            Text("设置")
                .font(Theme.TextStyle.section)
                .foregroundStyle(Theme.textPrimary)
            Text("电影元数据、网络代理与硬件能力")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Size.contentInset)
        .frame(height: 44)
        .background(Theme.bg)
    }

    // MARK: TMDB（设计文档 §7.5）

    @ViewBuilder
    private var tmdbSection: some View {
        InspectorSection(title: "TMDB 电影元数据") {
            HStack(spacing: Theme.Spacing.s1) {
                StatusDot(color: store.isTMDBConfigured ? Theme.success : Theme.textSecondary)
                Text(store.isTMDBConfigured ? "已配置（凭据存于系统钥匙串）" : "未配置（电影任务只能手动填写元数据）")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }

            SecureField("API Key（v3）或 Read Access Token（v4）", text: $credentialInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)

            if let validationMessage {
                Text(validationMessage)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.s2) {
                PrimaryButton(title: "验证并保存", isEnabled: !isSavingCredential) {
                    saveCredential()
                }
                if store.isTMDBConfigured {
                    TextButton(title: "移除已保存凭据") {
                        store.removeTMDB()
                        validationMessage = nil
                    }
                }
                TextButton(title: "清除元数据缓存") {
                    store.clearMetadataCache()
                }
            }

            Text("凭据只写入系统钥匙串，不写日志；仅勾选「电影」的任务联网（TMDB）。搜索、详情与海报数据本地缓存 7 天。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: 网络代理（设计文档 §7.5）

    @ViewBuilder
    private var proxySection: some View {
        @Bindable var store = store
        InspectorSection(title: "网络代理") {
            Toggle("通过代理访问 TMDB", isOn: $store.proxySettings.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.TextStyle.body)

            HStack(spacing: Theme.Spacing.s2) {
                Picker("类型", selection: $store.proxySettings.kind) {
                    ForEach(ProxySettings.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField("代理服务器地址", text: $store.proxySettings.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                HStack(spacing: Theme.Spacing.s1) {
                    Text("端口")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("7890", value: $store.proxySettings.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
            }
            .disabled(!store.proxySettings.isEnabled)

            if let message = store.proxySettings.validationMessage {
                Text(message)
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Spacing.s2) {
                TextButton(title: isTestingProxy ? "测试中…" : "测试连接", isEnabled: !isTestingProxy) {
                    testProxyConnection()
                }
                if let proxyTestMessage {
                    Text(proxyTestMessage)
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(proxyTestSucceeded ? Theme.success : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("国内直连 TMDB 常不可达，可在此填写本地代理（如 Clash 默认 127.0.0.1:7890）。代理只作用于 TMDB 的搜索、详情与海报；未启用时遵循系统代理设置。")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func testProxyConnection() {
        guard !isTestingProxy else { return }
        isTestingProxy = true
        proxyTestMessage = nil
        Task {
            let error = await store.testTMDBReachability()
            isTestingProxy = false
            proxyTestSucceeded = error == nil
            proxyTestMessage = error ?? "连接成功：已能访问 TMDB。"
        }
    }

    private func saveCredential() {
        guard !isSavingCredential else { return }
        isSavingCredential = true
        validationMessage = nil
        let input = credentialInput
        Task {
            let error = await store.validateAndSaveTMDB(input)
            isSavingCredential = false
            if let error {
                validationMessage = error
            } else {
                credentialInput = ""
            }
        }
    }

    @ViewBuilder
    private var hardwareSection: some View {
        InspectorSection(title: "硬件") {
            if let capabilities = store.capabilities {
                encoderRow(family: "H.264", codec: .h264, capabilities: capabilities)
                encoderRow(family: "HEVC", codec: .hevc, capabilities: capabilities)
                encoderRow(family: "ProRes", codec: .proRes422, capabilities: capabilities)
                decoderRow(capabilities.h264HardwareDecode)

                Text("转码强制硬件编码（RequireHardwareAcceleratedVideoEncoder）；没有对应硬件编码器时任务在准备阶段失败，不做静默软件回退。")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("正在检测硬件能力…")
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func encoderRow(family: String, codec: VideoCodec, capabilities: HardwareCapabilities) -> some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: capabilities.hardwareEncoder(for: codec) != nil ? Theme.success : Theme.textSecondary)
            Text(family)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text(capabilities.hardwareEncoder(for: codec)?.name ?? "无硬件编码器")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func decoderRow(_ supported: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s1) {
            StatusDot(color: supported ? Theme.success : Theme.textSecondary)
            Text("解码")
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text(supported ? "H.264 硬件解码可用" : "无 H.264 硬件解码")
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}
