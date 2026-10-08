import Foundation
import LocalAuthentication
import Security
import Synchronization

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

final class KeychainMutationAuthorization: Sendable {
    nonisolated private let cancelled = Mutex(false)
    nonisolated private let beforeMutation: @Sendable () -> Void

    nonisolated var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    nonisolated init(beforeMutation: @escaping @Sendable () -> Void = {}) {
        self.beforeMutation = beforeMutation
    }

    nonisolated func cancel() {
        cancelled.withLock { $0 = true }
    }

    nonisolated func checkBeforeMutation() throws {
        beforeMutation()
        guard !isCancelled else { throw CancellationError() }
    }
}

actor KeychainStore {
    nonisolated static let keychainInteractionQueue = DispatchQueue(
        label: "com.lycaennaa.sidekick.keychain-interaction"
    )
    // A new namespace intentionally leaves legacy app-scoped items untouched.
    nonisolated private static let defaultService = "com.lycaennaa.sidekick.twitch-token.v4"
    nonisolated private let service: String

    private struct Record: Sendable {
        let value: String
        let marker: Data?
    }

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func read(account: String) throws -> String? {
        try readRecord(account: account, allowsAuthenticationUI: false)?.value
    }

    func promptForAccess(account: String) throws -> String? {
        try readRecord(account: account, allowsAuthenticationUI: true)?.value
    }

    func write(
        _ value: String,
        replacing expectedValue: String?,
        account: String,
        authorization: KeychainMutationAuthorization = KeychainMutationAuthorization()
    ) throws {
        try Task.checkCancellation()
        guard let data = value.data(using: .utf8) else {
            throw KeychainStoreError.invalidData
        }

        // The marker below makes this re-read a compare-and-swap boundary after async validation.
        let current = try readRecord(account: account)
        try Task.checkCancellation()
        guard current?.value == expectedValue else {
            throw KeychainStoreError.conflict
        }

        if let current {
            guard let currentMarker = current.marker else {
                throw KeychainStoreError.conflict
            }
            let marker = Data(UUID().uuidString.utf8)
            try Task.checkCancellation()
            let status = try Self.keychainInteractionQueue.sync {
                try Self.withKeychainUserInteractionAllowed(false) {
                    try authorization.checkBeforeMutation()
                    var query = self.baseQuery(account: account)
                    query[kSecAttrGeneric as String] = currentMarker
                    return SecItemUpdate(
                        query as CFDictionary,
                        [
                            kSecValueData as String: data,
                            kSecAttrGeneric as String: marker
                        ] as CFDictionary
                    )
                }
            }
            if status == errSecSuccess {
                return
            }
            if status == errSecItemNotFound {
                throw KeychainStoreError.conflict
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }

        let marker = Data(UUID().uuidString.utf8)
        try Task.checkCancellation()
        let addStatus = try Self.keychainInteractionQueue.sync {
            try Self.withKeychainUserInteractionAllowed(false) {
                var query = self.baseQuery(account: account)
                try authorization.checkBeforeMutation()
                query[kSecAttrGeneric as String] = marker
                query[kSecValueData as String] = data
                return SecItemAdd(query as CFDictionary, nil)
            }
        }
        if addStatus == errSecDuplicateItem {
            throw KeychainStoreError.conflict
        }
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(
        account: String,
        authorization: KeychainMutationAuthorization = KeychainMutationAuthorization()
    ) throws {
        try Task.checkCancellation()
        let status = try Self.keychainInteractionQueue.sync {
            try Self.withKeychainUserInteractionAllowed(false) {
                try authorization.checkBeforeMutation()
                return SecItemDelete(self.baseQuery(account: account) as CFDictionary)
            }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(
        account: String,
        ifValueIs expectedValue: String,
        authorization: KeychainMutationAuthorization = KeychainMutationAuthorization()
    ) throws {
        try Task.checkCancellation()
        guard let current = try readRecord(account: account) else { return }
        guard current.value == expectedValue, let marker = current.marker else {
            throw KeychainStoreError.conflict
        }
        try Task.checkCancellation()
        let status = try Self.keychainInteractionQueue.sync {
            try Self.withKeychainUserInteractionAllowed(false) {
                try authorization.checkBeforeMutation()
                var query = self.baseQuery(account: account)
                query[kSecAttrGeneric as String] = marker
                return SecItemDelete(query as CFDictionary)
            }
        }
        if status == errSecItemNotFound {
            throw KeychainStoreError.conflict
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func readRecord(account: String, allowsAuthenticationUI: Bool = false) throws -> Record? {
        try Self.keychainInteractionQueue.sync {
            try Self.withKeychainUserInteractionAllowed(allowsAuthenticationUI) {
                var query = self.baseQuery(account: account)
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                query[kSecReturnAttributes as String] = true
                query[kSecReturnData as String] = true
                let authenticationContext = LAContext()
                authenticationContext.interactionNotAllowed = !allowsAuthenticationUI
                if allowsAuthenticationUI {
                    authenticationContext.localizedReason = "Allow Sidekick to access your Twitch token."
                }
                query[kSecUseAuthenticationContext as String] = authenticationContext
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
        }
    }

    nonisolated private static func withKeychainUserInteractionAllowed<Value>(
        _ interactionAllowed: Bool,
        operation: () throws -> Value
    ) throws -> Value {
        // SecItem's LAContext controls item authentication, not legacy Keychain ACL prompts.
        var previousState = DarwinBoolean(false)
        let getStatus = SecKeychainGetUserInteractionAllowed(&previousState)
        guard getStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(getStatus)
        }
        let setStatus = SecKeychainSetUserInteractionAllowed(interactionAllowed)
        guard setStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(setStatus)
        }
        do {
            let value = try operation()
            let restoreStatus = SecKeychainSetUserInteractionAllowed(previousState.boolValue)
            guard restoreStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(restoreStatus)
            }
            return value
        } catch {
            let restoreStatus = SecKeychainSetUserInteractionAllowed(previousState.boolValue)
            guard restoreStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(restoreStatus)
            }
            throw error
        }
    }

    nonisolated private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
