import Foundation
import os

/// 统一日志入口（设计文档 §12：不记录任何密钥/请求正文）。
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Chrysalis"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
