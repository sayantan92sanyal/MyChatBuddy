import Foundation
import Security

/// Hand-rolled macOS Keychain wrapper for API key storage. Kept dependency-free
/// since this is credential-handling code — owning it directly beats trusting a
/// small third-party wrapper.
public struct KeychainStore: Sendable {
    public enum KeychainStoreError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    private let service: String

    public init(service: String = "com.sayantan.aichatrouter") {
        self.service = service
    }

    public func setValue(_ value: String, forAccount account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainStoreError.encodingFailed }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let existsStatus = SecItemCopyMatching(query as CFDictionary, nil)
        if existsStatus == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(updateStatus)
            }
        } else if existsStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainStoreError.unexpectedStatus(existsStatus)
        }
    }

    public func value(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteValue(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
