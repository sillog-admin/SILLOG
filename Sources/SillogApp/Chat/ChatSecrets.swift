import Foundation
import Security

// One item for every account, because each rebuild changes the cdhash and the keychain asks once per item.
enum ChatSecrets {
    private static let service = "com.sillog.app.chat"
    private static let combinedAccount = "secrets"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?
    nonisolated(unsafe) private static var legacyMisses: Set<String> = []
    // An empty value from a failed read must not be saved back as a removal.
    nonisolated(unsafe) private static var failedLoads: Set<String> = []
    // Snapshot builds are unsigned, so reading the signed app's item would block on a Keychain prompt.
    nonisolated(unsafe) static var memoryOnly = false

    /// Args: account is the secret's name.
    /// Returns: the stored secret, or an empty string when there is none.
    /// Raises: NSOSStatusErrorDomain error when the keychain read fails or the stored item is unreadable.
    static func load(_ account: String) throws -> String {
        try lock.withLock {
            do {
                let value = try loadLocked(account)
                failedLoads.remove(account)
                return value
            } catch {
                failedLoads.insert(account)
                throw error
            }
        }
    }

    /// Args: value is the secret to store, account is the secret's name.
    /// Returns: nothing. An empty value removes the secret.
    /// Raises: NSOSStatusErrorDomain error when the keychain read, write or delete fails.
    static func save(_ value: String, account: String) throws {
        try lock.withLock {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && failedLoads.contains(account) { return }
            var secrets = try combined()
            secrets[account] = trimmed.isEmpty ? nil : trimmed
            try write(secrets)
            cache = secrets
            guard trimmed.isEmpty else { return }
            // A leftover old item would bring a removed secret back on the next launch.
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            legacyMisses.insert(account)
        }
    }

    private static func loadLocked(_ account: String) throws -> String {
        var secrets = try combined()
        if let value = secrets[account] { return value }
        if legacyMisses.contains(account) { return "" }
        guard let data = try read(account), let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            legacyMisses.insert(account)
            return ""
        }
        secrets[account] = value
        cache = secrets
        // Keep the old item if the move fails, so the secret is not lost.
        if (try? write(secrets)) != nil, SecItemDelete(query(account) as CFDictionary) == errSecSuccess { legacyMisses.insert(account) }
        return value
    }

    private static func combined() throws -> [String: String] {
        if let cache { return cache }
        guard let data = try read(combinedAccount) else { cache = [:]; return [:] }
        // Refuse to treat unreadable data as empty, or the next save would overwrite every secret.
        guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
        cache = secrets
        return secrets
    }

    private static func read(_ account: String) throws -> Data? {
        if memoryOnly { return nil }
        var item: CFTypeRef?
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return item as? Data ?? Data()
    }

    private static func write(_ secrets: [String: String]) throws {
        if memoryOnly { return }
        let item = query(combinedAccount), data = try JSONEncoder().encode(secrets)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
