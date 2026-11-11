import Foundation
import Security

enum ChatSecrets {
    /// Args: account는 서비스 키 이름이다.
    /// Returns: Keychain에 저장된 키. 없으면 빈 문자열.
    /// Raises: Keychain 접근 오류.
    static func load(_ account: String) throws -> String {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Args: value는 입력한 키, account는 서비스 키 이름이다.
    /// Returns: 없음. 빈 문자열이면 해당 키를 삭제한다.
    /// Raises: Keychain 저장·삭제 오류.
    static func save(_ value: String, account: String) throws {
        let query = base(account), data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status: OSStatus
        if data.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Args: account는 서비스 키 이름이다.
    /// Returns: 앱 전용 Keychain 조회 조건.
    /// Raises: 없음.
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.sillog.app.chat", kSecAttrAccount as String: account]
    }
}
