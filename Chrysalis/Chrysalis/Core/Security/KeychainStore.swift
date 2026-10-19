import Foundation
import os
import Security

/// 钥匙串（设计文档 §7.5）：TMDB 凭据存系统 Keychain，不写日志、不落盘。
enum KeychainStore {
    /// TMDB 凭据（v3 Key / v4 Token 原文）。
    static let tmdbAccount = "tmdb-credential"
    private static let defaultService = "dev.chrysalis.tmdb"

    @discardableResult
    static func save(_ secret: String, account: String, service: String = defaultService) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先删后加，避免 duplicate item
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            // 只记录状态码，绝不记录凭据内容
            Log.app.error("Keychain 写入失败（status \(status)）")
            return false
        }
        return true
    }

    static func read(account: String, service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty else {
            return nil
        }
        return secret
    }

    @discardableResult
    static func delete(account: String, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - TMDB 便捷操作

    @discardableResult
    static func saveTMDB(_ credential: String) -> Bool {
        save(credential, account: tmdbAccount)
    }

    static func readTMDB() -> String? {
        read(account: tmdbAccount)
    }

    static func deleteTMDB() {
        delete(account: tmdbAccount)
    }
}
