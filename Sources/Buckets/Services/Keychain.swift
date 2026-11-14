import Foundation
import Security
import os

/// Stores each connection's secret access key in the user's login keychain.
enum Keychain {
    private static let service = "com.zacksmash.Buckets.secrets"
    /// Where earlier builds kept secrets. Those items only trust the exact (ad hoc signed) build that
    /// wrote them, so every other build is asked for the password. A secret found there is copied into
    /// a fresh item written by this build, which trusts it from then on. The old items are left alone:
    /// deleting them could ask for the password again.
    private static let legacyServices = ["com.zacksmash.Buckets.credentials", "com.maxconnect.Buckets.credentials"]

    /// Secrets already read this run. Each Keychain read can ask the user for their password
    /// (until they choose Always Allow), so ask once per connection, not on every bucket switch.
    private static var cache: [UUID: String] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ id: UUID) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[id]
    }

    private static func remember(_ secret: String?, for id: UUID) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[id] = secret
    }

    static func setSecret(_ secret: String, for id: UUID) throws {
        defer { remember(secret, for: id) }
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
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    static func secret(for id: UUID) -> String? {
        if let secret = cached(id) { return secret }
        if let secret = read(service: service, id: id) { remember(secret, for: id); return secret }
        for legacy in legacyServices {
            guard let old = read(service: legacy, id: id) else { continue }
            try? setSecret(old, for: id)
            remember(old, for: id)
            return old
        }
        return nil
    }

    private static func read(service: String, id: UUID) -> String? {
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
        remember(nil, for: id)
        delete(service: service, id: id)
        for legacy in legacyServices { delete(service: legacy, id: id) }
    }

    private static func delete(service: String, id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Logger(subsystem: "com.zacksmash.Buckets", category: "Keychain")
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
