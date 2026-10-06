import Foundation
import Security

enum KeychainStoreError: Error, LocalizedError, Equatable {
    case invalidData
    case conflict
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "Keychain returned invalid data."
        case .conflict:
            "Keychain item changed while it was being saved."
        case let .unexpectedStatus(status):
            "Keychain operation failed (status \(status))."
        }
    }
}

final class KeychainStore {
    // A new namespace intentionally leaves legacy app-scoped items untouched.
    private static let defaultService = "com.lycaennaa.sidekick.twitch-token.v4"
    private let service: String

    private struct Record {
        let value: String
        let marker: Data?
    }

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func read(account: String) throws -> String? {
        try readRecord(account: account)?.value
    }

    func write(_ value: String, replacing expectedValue: String?, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        let current = try readRecord(account: account)
        guard current?.value == expectedValue else {
            throw KeychainStoreError.conflict
        }

        if let current {
            guard let currentMarker = current.marker else {
                throw KeychainStoreError.conflict
            }
            var query = baseQuery(account: account)
            query[kSecAttrGeneric as String] = currentMarker
            let marker = Data(UUID().uuidString.utf8)
            let status = SecItemUpdate(
                query as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrGeneric as String: marker
                ] as CFDictionary
            )
            if status == errSecSuccess {
                return
            }
            if status == errSecItemNotFound {
                throw KeychainStoreError.conflict
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }

        let marker = Data(UUID().uuidString.utf8)
        var query = baseQuery(account: account)
        query[kSecAttrGeneric as String] = marker
        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            throw KeychainStoreError.conflict
        }
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func readRecord(account: String) throws -> Record? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return Record(
            value: value,
            marker: attributes[kSecAttrGeneric as String] as? Data
        )
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
