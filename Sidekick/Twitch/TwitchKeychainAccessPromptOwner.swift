import Foundation

@MainActor
final class TwitchKeychainAccessPromptOwner {
    private let request: @Sendable () async throws -> String?
    private var didRequestAtStartup = false
    private var didPromptManually = false
    private var generation: UInt64 = 0
    private var terminating = false
    private(set) var isRequesting = false

    init(request: @escaping @Sendable () async throws -> String?) {
        self.request = request
    }

    var canPromptManually: Bool {
        !terminating && !didPromptManually && !isRequesting
    }

    func requestAtStartup(
        onStarted: @MainActor () -> Void = {}
    ) async -> Result<String?, Error>? {
        guard !terminating, !didRequestAtStartup else { return nil }
        didRequestAtStartup = true
        return await performRequest(onStarted: onStarted)
    }

    func promptManually(
        onStarted: @MainActor () -> Void = {}
    ) async -> Result<String?, Error>? {
        guard canPromptManually else { return nil }
        didPromptManually = true
        return await performRequest(onStarted: onStarted)
    }

    func finishRequest() {
        isRequesting = false
    }

    func terminate() {
        guard !terminating else { return }
        terminating = true
        generation &+= 1
        isRequesting = false
    }

    private func performRequest(
        onStarted: @MainActor () -> Void
    ) async -> Result<String?, Error>? {
        guard !terminating, !isRequesting else { return nil }
        generation &+= 1
        let requestGeneration = generation
        isRequesting = true
        onStarted()
        let result: Result<String?, Error>
        do {
            result = .success(try await request())
        } catch {
            result = .failure(error)
        }
        let wasCancelled = Task.isCancelled
        guard !terminating,
              generation == requestGeneration,
              isRequesting else { return nil }
        return wasCancelled ? .failure(CancellationError()) : result
    }
}
