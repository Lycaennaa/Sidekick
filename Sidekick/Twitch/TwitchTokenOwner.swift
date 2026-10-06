import Foundation

@MainActor
final class TwitchTokenOwner {
    struct Dependencies: Sendable {
        let read: @MainActor @Sendable () throws -> String?
        let write: @MainActor @Sendable (String, String?) throws -> Void
        let delete: @MainActor @Sendable () throws -> Void
        let authenticate: @Sendable (String) async throws -> Void
    }

    enum StorageError: Error {
        case read
        case write
        case delete
    }

    enum StoredTokenState: Equatable, Sendable {
        case absent
        case present(String)
        case readFailure
    }

    enum SaveResult: Equatable {
        case rejected(token: String, message: String)
        case saved(token: String, changed: Bool)
        case validating(token: String, changed: Bool)
    }

    enum Event: Equatable {
        case saved(String)
        case failed(token: String, message: String)
    }

    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var errorMessage: String?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isSaving: Bool {
        task != nil
    }

    func storedTokenState() -> StoredTokenState {
        do {
            guard let token = try dependencies.read(), !token.isEmpty else {
                return .absent
            }
            return .present(token)
        } catch {
            return .readFailure
        }
    }

    func save(
        _ rawToken: String,
        notificationsEnabled: Bool,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) -> SaveResult {
        let token = TwitchOAuthToken.normalized(rawToken)
        guard !token.isEmpty else {
            return .rejected(token: token, message: "enter an oauth token before saving")
        }

        errorMessage = nil
        cancel()
        let existingToken: String?
        do {
            existingToken = try dependencies.read()
        } catch {
            return .rejected(token: token, message: "could not read oauth token from keychain")
        }

        guard existingToken != token else {
            return .saved(token: token, changed: false)
        }

        if !notificationsEnabled, existingToken == nil {
            do {
                try dependencies.write(token, existingToken)
                return .saved(token: token, changed: true)
            } catch {
                return .rejected(token: token, message: "could not save oauth token to keychain")
            }
        }

        generation &+= 1
        let requestedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.validateAndSave(
                token: token,
                requestedGeneration: requestedGeneration,
                expectedToken: existingToken,
                onEvent: onEvent
            )
        }
        return .validating(token: token, changed: true)
    }

    private func validateAndSave(
        token: String,
        requestedGeneration: UInt64,
        expectedToken: String?,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async {
        let hasExistingToken = expectedToken != nil
        do {
            try await dependencies.authenticate(token)
            guard isCurrent(requestedGeneration) else { return }
            guard commitValidatedToken(
                token: token,
                requestedGeneration: requestedGeneration,
                expectedToken: expectedToken,
                hasExistingToken: hasExistingToken,
                onEvent: onEvent
            ) else { return }
        } catch is CancellationError {
            return
        } catch let error as TwitchAPIClient.APIError {
            guard isCurrent(requestedGeneration) else { return }
            finishFailure(
                validationFailureMessage(
                    for: error,
                    hasExistingToken: hasExistingToken
                ),
                token: token,
                onEvent: onEvent
            )
        } catch {
            guard isCurrent(requestedGeneration) else { return }
            finishFailure(
                hasExistingToken
                    ? "could not validate new oauth token; existing token kept"
                    : "could not validate new oauth token",
                token: token,
                onEvent: onEvent
            )
        }
    }

    private func commitValidatedToken(
        token: String,
        requestedGeneration: UInt64,
        expectedToken: String?,
        hasExistingToken: Bool,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) -> Bool {
        guard isCurrent(requestedGeneration) else { return false }

        let currentToken: String?
        do {
            currentToken = try dependencies.read()
        } catch {
            finishFailure(
                hasExistingToken
                    ? "could not re-read oauth token; existing token kept"
                    : "could not re-read oauth token",
                token: token,
                onEvent: onEvent
            )
            return false
        }
        guard currentToken == expectedToken else {
            finishFailure(
                "oauth token changed while validation was running; newer token kept",
                token: token,
                onEvent: onEvent
            )
            return false
        }

        do {
            try dependencies.write(token, expectedToken)
        } catch let error as KeychainStoreError where error == .conflict {
            finishFailure(
                "oauth token changed while validation was running; newer token kept",
                token: token,
                onEvent: onEvent
            )
            return false
        } catch {
            finishFailure(
                "could not save oauth token to keychain",
                token: token,
                onEvent: onEvent
            )
            return false
        }
        task = nil
        errorMessage = nil
        onEvent(.saved(token))
        return true
    }

    func remove() -> Result<Void, StorageError> {
        errorMessage = nil
        cancel()
        do {
            try dependencies.delete()
            return .success(())
        } catch {
            return .failure(.delete)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    func clearError() {
        errorMessage = nil
    }

    private func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && task != nil
    }

    private func finishFailure(
        _ message: String,
        token: String,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) {
        task = nil
        errorMessage = message
        onEvent(.failed(token: token, message: message))
    }

    private func validationFailureMessage(
        for error: TwitchAPIClient.APIError,
        hasExistingToken: Bool
    ) -> String {
        switch error {
        case .invalidToken:
            hasExistingToken
                ? "new oauth token is invalid; existing token kept"
                : "new oauth token is invalid"
        case .missingFollowedStreamsScope:
            hasExistingToken
                ? "new token needs user:read:follows; existing token kept"
                : "new token needs user:read:follows"
        case .network:
            hasExistingToken
                ? "id.twitch.tv unreachable; existing token kept"
                : "id.twitch.tv unreachable"
        default:
            hasExistingToken
                ? "could not validate new oauth token; existing token kept"
                : "could not validate new oauth token"
        }
    }
}
