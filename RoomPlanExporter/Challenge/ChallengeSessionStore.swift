import Foundation
import Security

struct ChallengePendingSubmission: Codable {
    let key: UUID
    let elapsed: Int
    let objects: [ChallengeObjectEdit]
}

struct ChallengeSavedSession: Codable {
    let eventId: Int
    let token: String
    var pending: ChallengePendingSubmission?
}

/// A participant can resume on this device without storing their phone number.
/// Pending requests survive app termination with the same idempotency key.
enum ChallengeSessionStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "vo") + ".challenge",
         kSecAttrAccount as String: "participant-session"]
    }

    static func load() -> ChallengeSavedSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChallengeSavedSession.self, from: data)
    }

    static func save(_ session: ChallengeSavedSession) throws {
        let data = try JSONEncoder().encode(session)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw APIError(statusCode: 0, detail: "참가 정보를 기기에 저장하지 못했어요. 기기 잠금을 해제한 뒤 다시 시도해 주세요.")
        }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
