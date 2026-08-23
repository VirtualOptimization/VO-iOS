import Foundation
import Security

// MARK: - Keychain 기반 토큰 저장소

enum KeychainTokenStore {
    enum Key: String {
        case accessToken  = "vo_access_token"
        case refreshToken = "vo_refresh_token"
    }

    private static let service = "com.example.apple-samplecode.RoomPlanExporter"

    static func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
