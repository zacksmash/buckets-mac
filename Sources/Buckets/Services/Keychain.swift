import Foundation
import Security
import os

/// Stores each connection's secret access key in the user's login keychain.
enum Keychain {
    private static let service = "com.maxconnect.Buckets.credentials"

    static func setSecret(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Buckets – Secret Access Key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    static func secret(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger(subsystem: "com.maxconnect.Buckets", category: "Keychain")
                .error("Couldn't delete a secret from the Keychain (status \(status, privacy: .public))")
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Couldn't save to the Keychain: \(message)"
        }
        return "Couldn't save to the Keychain (error \(status))."
    }
}
