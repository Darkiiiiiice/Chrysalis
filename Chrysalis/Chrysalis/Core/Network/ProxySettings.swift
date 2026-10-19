import CFNetwork
import Foundation

/// TMDB 网络代理设置（设计文档 §7.5）。
///
/// 国内直连 `api.themoviedb.org` / `image.tmdb.org` 常不可达，设置页可配置本地代理
/// （Clash / Surge 等，默认 `127.0.0.1:7890`）。代理只作用于 TMDB 请求；未启用时
/// 遵循系统代理设置。v1 不支持代理用户名/密码认证。
struct ProxySettings: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case http
        case socks5

        var displayName: String {
            switch self {
            case .http: "HTTP / HTTPS"
            case .socks5: "SOCKS5"
            }
        }
    }

    var isEnabled: Bool
    var kind: Kind
    var host: String
    var port: Int

    /// 默认对齐常见本地代理客户端（Clash / Surge 等）。
    static let `default` = ProxySettings(isEnabled: false, kind: .http, host: "127.0.0.1", port: 7890)

    /// 启用时的中文校验提示；nil 表示合法。
    var validationMessage: String? {
        guard isEnabled else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            return "代理服务器地址不能为空。"
        }
        if trimmedHost.contains("://") || trimmedHost.contains("/")
            || trimmedHost.contains(":") || trimmedHost.contains(" ") {
            return "只填代理主机名或 IP，不要带协议与端口（端口在右侧单独填写）。"
        }
        guard (1...65535).contains(port) else {
            return "端口需在 1–65535 之间。"
        }
        return nil
    }

    /// `URLSessionConfiguration.connectionProxyDictionary`；未启用或参数非法时返回 nil（不走代理）。
    var connectionProxyDictionary: [AnyHashable: Any]? {
        guard isEnabled, validationMessage == nil else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: trimmedHost,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: trimmedHost,
                kCFNetworkProxiesHTTPSPort: port,
            ]
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable: true,
                kCFNetworkProxiesSOCKSProxy: trimmedHost,
                kCFNetworkProxiesSOCKSPort: port,
            ]
        }
    }
}

/// 代理设置持久化（UserDefaults；JSON 编码，键 `dev.chrysalis.proxy`）。
enum ProxySettingsStore {
    static let defaultsKey = "dev.chrysalis.proxy"

    static func load(from defaults: UserDefaults = .standard) -> ProxySettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ProxySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: ProxySettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// 按当前代理设置构建/复用 `URLSession`（设计文档 §7.5）。
///
/// 每次取用会话时读取最新设置；设置变化自动重建（改设置后立即生效，无需重启）。
final class ProxySessionProvider: @unchecked Sendable {
    private let loadSettings: @Sendable () -> ProxySettings
    private let lock = NSLock()
    private var cachedSession: URLSession?
    private var cachedSettings: ProxySettings?

    init(loadSettings: @escaping @Sendable () -> ProxySettings = { ProxySettingsStore.load() }) {
        self.loadSettings = loadSettings
    }

    /// 当前会话：设置未变时复用，变化时重建。
    func session() -> URLSession {
        let settings = loadSettings()
        lock.lock()
        defer { lock.unlock() }
        if let cachedSession, cachedSettings == settings {
            return cachedSession
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.connectionProxyDictionary = settings.connectionProxyDictionary
        let session = URLSession(configuration: configuration)
        cachedSession = session
        cachedSettings = settings
        return session
    }
}
