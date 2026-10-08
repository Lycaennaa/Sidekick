import Foundation

@MainActor
extension TwitchNotificationController {
    static func makeLiveTokenOwner(
        keychain: KeychainStore,
        apiClient: TwitchAPIClient,
        account: String
    ) -> TwitchTokenOwner {
        TwitchTokenOwner(
            dependencies: .init(
                read: { try await keychain.read(account: account) },
                write: { token, expected, authorization in
                    try await keychain.write(
                        token,
                        replacing: expected,
                        account: account,
                        authorization: authorization
                    )
                },
                delete: { expected, authorization in
                    try await keychain.delete(
                        account: account,
                        ifValueIs: expected,
                        authorization: authorization
                    )
                },
                authenticate: { token in
                    _ = try await apiClient.authenticate(accessToken: token)
                }
            )
        )
    }

    var oauthTokenState: TwitchTokenOwner.StoredTokenState {
        tokenOwner.storedTokenState()
    }

    var canPromptForKeychainAccess: Bool {
        keychainAccessPromptOwner.canPromptManually
            && !tokenOwner.isSaving
            && pendingOAuthTokenSave == nil
    }

    var isRequestingKeychainAccess: Bool {
        keychainAccessPromptOwner.isRequesting
    }

    func refreshStoredKeychainTokenState() {
        tokenOwner.refreshStoredTokenState { [weak self] state in
            guard let self,
                  !self.terminating,
                  self.settings.twitchNotificationsEnabled,
                  !self.tokenOwner.isSaving,
                  !self.keychainAccessPromptOwner.isRequesting else { return }
            self.applySettings(storedTokenState: state)
            self.onStateChange?()
        }
    }

    func requestKeychainAccessAtStartup() async {
        let mutationGeneration = tokenOwner.mutationGeneration
        guard let result = await keychainAccessPromptOwner.requestAtStartup(onStarted: { [weak self] in
            self?.onStateChange?()
        }) else { return }
        guard !Task.isCancelled, tokenOwner.mutationGeneration == mutationGeneration else {
            keychainAccessPromptOwner.finishRequest()
            return
        }
        handleKeychainAccessResult(result)
    }

    func promptForKeychainAccess() async {
        guard canPromptForKeychainAccess else { return }
        let mutationGeneration = tokenOwner.mutationGeneration
        guard let result = await keychainAccessPromptOwner.promptManually(onStarted: { [weak self] in
            self?.onStateChange?()
        }) else { return }
        guard !Task.isCancelled, tokenOwner.mutationGeneration == mutationGeneration else {
            keychainAccessPromptOwner.finishRequest()
            return
        }
        handleKeychainAccessResult(result)
    }

    func handleKeychainAccessResult(_ result: Result<String?, Error>) {
        guard !terminating else {
            keychainAccessPromptOwner.finishRequest()
            return
        }
        let state: TwitchTokenOwner.StoredTokenState
        switch result {
        case let .success(token):
            state = token.map(TwitchTokenOwner.StoredTokenState.present) ?? .absent
        case .failure:
            state = .readFailure
        }
        tokenOwner.setStoredTokenState(state)
        keychainAccessPromptOwner.finishRequest()
        applySettings(storedTokenState: state)
        if let pendingToken = pendingOAuthTokenSave {
            pendingOAuthTokenSave = nil
            _ = saveOAuthToken(pendingToken)
        }
        onStateChange?()
    }
    var tokenSaveErrorMessage: String? {
        tokenOwner.errorMessage
    }

    var testNotificationErrorMessage: String? {
        testNotificationOwner.errorMessage
    }
}
