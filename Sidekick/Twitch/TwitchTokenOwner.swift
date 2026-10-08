import Foundation

@MainActor
final class TwitchTokenOwner {
    struct Dependencies: Sendable {
        let read: @Sendable () async throws -> String?
        let write: @Sendable (String, String?, KeychainMutationAuthorization) async throws -> Void
        let delete: @Sendable (String, KeychainMutationAuthorization) async throws -> Void
        let authenticate: @Sendable (String) async throws -> Void
    }

    enum StorageError: Error {
        case read
        case write
        case delete
    }

    enum StoredTokenState: Equatable, Sendable {
        case loading
        case absent
        case present(String)
        case readFailure
    }

    enum SaveResult: Equatable {
        case rejected(token: String, message: String)
        case validating(token: String)
    }

    enum Event: Equatable {
        case saved(token: String, changed: Bool)
        case failed(token: String, message: String)
    }

    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var errorMessage: String?
    private var storedTokenReadTask: Task<Void, Never>?
    private var storedTokenReadGeneration: UInt64 = 0
    private var storedTokenStateValue: StoredTokenState = .loading
    private var mutationAuthorization: KeychainMutationAuthorization?
    private var tokenMutationGeneration: UInt64 = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isSaving: Bool {
        task != nil
    }

    var mutationGeneration: UInt64 {
        tokenMutationGeneration
    }

    func storedTokenState() -> StoredTokenState {
        storedTokenStateValue
    }

    func setStoredTokenState(_ state: StoredTokenState) {
        storedTokenReadGeneration &+= 1
        storedTokenReadTask?.cancel()
        storedTokenReadTask = nil
        storedTokenStateValue = state
    }

    func refreshStoredTokenState(
        onCompletion: @escaping @MainActor @Sendable (StoredTokenState) -> Void
    ) {
        guard task == nil, storedTokenReadTask == nil else { return }
        storedTokenReadGeneration &+= 1
        let requestedGeneration = storedTokenReadGeneration
        storedTokenReadTask = Task { [weak self] in
            guard let self else { return }
            let state = await self.readStoredTokenState()
            guard !Task.isCancelled,
                  self.storedTokenReadGeneration == requestedGeneration,
                  self.storedTokenReadTask != nil,
                  self.task == nil else { return }
            self.storedTokenReadTask = nil
            self.storedTokenStateValue = state
            onCompletion(state)
        }
    }

    private func readStoredTokenState() async -> StoredTokenState {
        do {
            guard let token = try await dependencies.read(), !token.isEmpty else {
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
        tokenMutationGeneration &+= 1
        let previousTask = task
        let previousStoredTokenReadTask = storedTokenReadTask
        let authorization = KeychainMutationAuthorization()
        cancel()
        mutationAuthorization = authorization
        let requestedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard self.isCurrent(requestedGeneration) else { return }
            await previousStoredTokenReadTask?.value
            guard self.isCurrent(requestedGeneration) else { return }
            await self.prepareSave(
                token: token,
                notificationsEnabled: notificationsEnabled,
                requestedGeneration: requestedGeneration,
                authorization: authorization,
                onEvent: onEvent
            )
        }
        return .validating(token: token)
    }

    private func prepareSave(
        token: String,
        notificationsEnabled: Bool,
        requestedGeneration: UInt64,
        authorization: KeychainMutationAuthorization,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async {
        let existingToken = await existingTokenForSave(
            token: token,
            requestedGeneration: requestedGeneration,
            onEvent: onEvent
        )
        guard isCurrent(requestedGeneration) else { return }
        guard existingToken != token else {
            finishSuccess(token, changed: false, onEvent: onEvent)
            return
        }
        if !notificationsEnabled, existingToken == nil {
            await saveUnvalidatedToken(
                token: token,
                requestedGeneration: requestedGeneration,
                authorization: authorization,
                onEvent: onEvent
            )
            return
        }
        await validateAndSave(
            token: token,
            requestedGeneration: requestedGeneration,
            expectedToken: existingToken,
            authorization: authorization,
            onEvent: onEvent
        )
    }

    private func validateAndSave(
        token: String,
        requestedGeneration: UInt64,
        expectedToken: String?,
        authorization: KeychainMutationAuthorization,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async {
        let hasExistingToken = expectedToken != nil
        do {
            try await dependencies.authenticate(token)
            guard isCurrent(requestedGeneration) else { return }
            guard await commitValidatedToken(
                token: token,
                requestedGeneration: requestedGeneration,
                expectedToken: expectedToken,
                authorization: authorization,
                onEvent: onEvent
            ) else { return }
        } catch is CancellationError {
            return
        } catch let error as TwitchAPIClient.APIError {
            guard isCurrent(requestedGeneration) else { return }
            await finishFailureAfterRefreshingStoredToken(
                token: token,
                requestedGeneration: requestedGeneration,
                message: validationFailureMessage(
                    for: error,
                    hasExistingToken: hasExistingToken
                ),
                onEvent: onEvent
            )
        } catch {
            guard isCurrent(requestedGeneration) else { return }
            await finishFailureAfterRefreshingStoredToken(
                token: token,
                requestedGeneration: requestedGeneration,
                message: hasExistingToken
                    ? "could not validate new oauth token; existing token kept"
                    : "could not validate new oauth token",
                onEvent: onEvent
            )
        }
    }

    private func commitValidatedToken(
        token: String,
        requestedGeneration: UInt64,
        expectedToken: String?,
        authorization: KeychainMutationAuthorization,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) async -> Bool {
        guard isCurrent(requestedGeneration) else { return false }
        do {
            try await dependencies.write(token, expectedToken, authorization)
        } catch let error as KeychainStoreError where error == .conflict {
            await finishFailureAfterRefreshingStoredToken(
                token: token,
                requestedGeneration: requestedGeneration,
                message: "oauth token changed while validation was running; newer token kept",
                onEvent: onEvent
            )
            return false
        } catch {
            guard isCurrent(requestedGeneration) else { return false }
            finishFailure(
                "could not save oauth token to keychain",
                token: token,
                onEvent: onEvent
            )
            return false
        }
        guard isCurrent(requestedGeneration) else { return false }
        finishSuccess(token, changed: true, onEvent: onEvent)
        return true
    }

    func remove(
        onCompletion: @escaping @MainActor @Sendable (Result<Void, StorageError>) -> Void
    ) {
        let expectedToken: String
        guard case let .present(token) = storedTokenStateValue else {
            onCompletion(.failure(.delete))
            return
        }
        expectedToken = token
        errorMessage = nil
        tokenMutationGeneration &+= 1
        let previousTask = task
        let previousStoredTokenReadTask = storedTokenReadTask
        let authorization = KeychainMutationAuthorization()
        cancel()
        mutationAuthorization = authorization
        let requestedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard self.isCurrent(requestedGeneration) else { return }
            await previousStoredTokenReadTask?.value
            guard self.isCurrent(requestedGeneration) else { return }
            let result: Result<Void, StorageError>
            do {
                try await self.dependencies.delete(expectedToken, authorization)
                result = .success(())
            } catch {
                result = .failure(.delete)
            }
            guard self.isCurrent(requestedGeneration) else { return }
            if case .success = result {
                self.setStoredTokenState(.absent)
                self.tokenMutationGeneration &+= 1
            }
            self.mutationAuthorization = nil
            self.task = nil
            onCompletion(result)
        }
    }

    func cancel() {
        mutationAuthorization?.cancel()
        mutationAuthorization = nil
        task?.cancel()
        task = nil
        generation &+= 1
        storedTokenReadGeneration &+= 1
        storedTokenReadTask?.cancel()
        storedTokenReadTask = nil

    }
    func clearError() {
        errorMessage = nil
    }

    private func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && task != nil
    }

    private func finishSuccess(
        _ token: String,
        changed: Bool,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) {
        task = nil
        mutationAuthorization = nil
        if changed { tokenMutationGeneration &+= 1 }
        setStoredTokenState(.present(token))
        errorMessage = nil
        onEvent(.saved(token: token, changed: changed))
    }

    private func finishFailure(
        _ message: String,
        token: String,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) {
        task = nil
        mutationAuthorization = nil
        errorMessage = message
        onEvent(.failed(token: token, message: message))
    }

}

private extension TwitchTokenOwner {
    func validationFailureMessage(
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
    private func finishFailureAfterRefreshingStoredToken(
        token: String,
        requestedGeneration: UInt64,
        message: String,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) async {
        guard isCurrent(requestedGeneration) else { return }
        let currentState = await readStoredTokenState()
        guard isCurrent(requestedGeneration) else { return }
        setStoredTokenState(currentState)
        finishFailure(message, token: token, onEvent: onEvent)
    }

    private func existingTokenForSave(
        token: String,
        requestedGeneration: UInt64,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) async -> String? {
        switch storedTokenStateValue {
        case let .present(token):
            return token
        case .absent:
            return nil
        case .loading, .readFailure:
            let storedToken: String?
            do {
                storedToken = try await dependencies.read()
            } catch {
                guard isCurrent(requestedGeneration) else { return nil }
                setStoredTokenState(.readFailure)
                finishFailure(
                    "could not read oauth token from keychain",
                    token: token,
                    onEvent: onEvent
                )
                return nil
            }
            guard isCurrent(requestedGeneration) else { return nil }
            guard let storedToken, !storedToken.isEmpty else {
                setStoredTokenState(.absent)
                return nil
            }
            setStoredTokenState(.present(storedToken))
            return storedToken
        }
    }

    private func saveUnvalidatedToken(
        token: String,
        requestedGeneration: UInt64,
        authorization: KeychainMutationAuthorization,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async {
        do {
            try await dependencies.write(token, nil, authorization)
        } catch let error as KeychainStoreError where error == .conflict {
            await finishFailureAfterRefreshingStoredToken(
                token: token,
                requestedGeneration: requestedGeneration,
                message: "oauth token changed while save was running; newer token kept",
                onEvent: onEvent
            )
            return
        } catch {
            guard isCurrent(requestedGeneration) else { return }
            finishFailure(
                "could not save oauth token to keychain",
                token: token,
                onEvent: onEvent
            )
            return
        }
        guard isCurrent(requestedGeneration) else { return }
        finishSuccess(token, changed: true, onEvent: onEvent)
    }
}
