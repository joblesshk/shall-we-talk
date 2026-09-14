import Foundation
import Security

/// 本机 API token 存储。旧版 UserDefaults 值首次读取时迁入钥匙串并删除；不再将密钥写入 iCloud Drive。
enum KeychainSecretStore {
    private static let service = "org.example.voicepen.credentials"

    static func string(for key: String) -> String {
        if let value = read(key), !value.isEmpty { return value }
        let legacy = UserDefaults.standard.string(forKey: key) ?? ""
        guard !legacy.isEmpty, write(legacy, for: key) else { return "" }
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func set(_ value: String, for key: String) {
        if value.isEmpty {
            SecItemDelete(query(for: key) as CFDictionary)
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard write(value, for: key) else {
            NSLog("Keychain write failed for credential key %@", key)
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func read(_ key: String) -> String? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func write(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query = query(for: key)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func query(for key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
