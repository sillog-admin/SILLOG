import Foundation
import Security
import SillogCore

// One item for every account, because each rebuild changes the cdhash and the keychain asks once per item.
enum ChatSecrets {
    private static let service = "com.sillog.app.chat"
    private static let combinedAccount = "secrets"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?
    nonisolated(unsafe) private static var legacyMisses: Set<String> = []
    // An empty value from a failed read must not be saved back as a removal.
    nonisolated(unsafe) private static var failedLoads: Set<String> = []
    // A denied or locked read is remembered, or every connector check would prompt again.
    // shortcut: failure kept until next save or relaunch, add a manual retry if users get stuck
    nonisolated(unsafe) private static var readFailure: Error?
    nonisolated(unsafe) private static var legacyFailures: [String: Error] = [:]
    // Snapshot builds are unsigned, so reading the signed app's item would block on a Keychain prompt.
    nonisolated(unsafe) static var memoryOnly = false
    // Names of accounts that hold a secret, so launch skips the prompting read for empty ones. Never values.
    nonisolated(unsafe) static var defaults: UserDefaults? = .standard
    private static let accountsKey = "sillog.chat.secretAccounts"

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
            readFailure = nil
            legacyFailures[account] = nil
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && failedLoads.contains(account) { return }
            let known = knownAccounts
            if trimmed.isEmpty, let known, !known.contains(account) { return }
            var secrets = try combined()
            var names = known ?? listed(secrets)
            secrets[account] = trimmed.isEmpty ? nil : trimmed
            try write(secrets)
            cache = secrets
            guard trimmed.isEmpty else { names?.insert(account); remember(names); return }
            // A leftover old item would bring a removed secret back on the next launch.
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            legacyMisses.insert(account)
            names?.remove(account); remember(names)
        }
    }

    private static func loadLocked(_ account: String) throws -> String {
        let known = knownAccounts
        if let known, !known.contains(account) { return "" }
        var secrets = try combined()
        if known == nil { remember(listed(secrets)) }
        if let value = secrets[account] { return value }
        if legacyMisses.contains(account) { return "" }
        if let failure = legacyFailures[account] { throw failure }
        let legacy: Data?
        do { legacy = try read(account) } catch { legacyFailures[account] = error; logFailure("read \(account)", error); throw error }
        guard let data = legacy, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            legacyMisses.insert(account)
            return ""
        }
        secrets[account] = value
        cache = secrets
        // Keep the old item if the move fails, so the secret is not lost.
        do { try write(secrets) } catch { logFailure("write", error); return value }
        let deleted = SecItemDelete(query(account) as CFDictionary)
        if deleted == errSecSuccess { legacyMisses.insert(account) } else { AppLog.write("keychain delete \(account) failed: \(deleted)") }
        return value
    }

    private static func combined() throws -> [String: String] {
        if let cache { return cache }
        if let readFailure { throw readFailure }
        let data: Data?
        do { data = try read(combinedAccount) } catch { readFailure = error; logFailure("read combined", error); throw error }
        guard let data else { cache = [:]; return [:] }
        // Refuse to treat unreadable data as empty, or the next save would overwrite every secret.
        guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
        cache = secrets
        return secrets
    }

    private static func logFailure(_ step: String, _ error: Error) {
        AppLog.write("keychain \(step) failed: \((error as NSError).code)")
    }

    private static var knownAccounts: Set<String>? { defaults?.stringArray(forKey: accountsKey).map(Set.init) }

    private static func remember(_ names: Set<String>?) {
        if let names { defaults?.set(names.sorted(), forKey: accountsKey) }
    }

    /// Returns: the combined item's accounts plus old per-account items, or nil when the old items can't be listed.
    private static func listed(_ secrets: [String: String]) -> Set<String>? {
        if memoryOnly { return Set(secrets.keys) }
        // Attributes only, so this does not prompt.
        let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &items)
        if status == errSecItemNotFound { return Set(secrets.keys) }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else { return nil }
        return Set(secrets.keys).union(rows.compactMap { $0[kSecAttrAccount as String] as? String }).subtracting([combinedAccount])
    }

    static func resetForTests() {
        lock.withLock { cache = nil; legacyMisses = []; failedLoads = []; readFailure = nil; legacyFailures = [:] }
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
