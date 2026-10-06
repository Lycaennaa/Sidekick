import UserNotifications

@MainActor
final class TwitchNotificationScheduler {
    struct Scope: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private struct State {
        var activeGeneration: UInt64?
        var pendingIdentifiers: Set<String> = []
        var inFlightIdentifiers: Set<String> = []
        var pendingRevision: UInt64 = 0
    }

    private let notifications: TwitchNotificationCenterClient
    private let sleeper: TwitchSleepClient
    private let cleanupInterval: TimeInterval
    private let defaultScope: Scope
    private var nextScopeID: UInt64 = 1
    private var states: [Scope: State]
    private var cleanupTask: Task<Void, Never>?
    private var cleanupGeneration: UInt64 = 0

    init(
        notifications: TwitchNotificationCenterClient,
        sleeper: TwitchSleepClient = .live,
        cleanupInterval: TimeInterval = 2
    ) {
        self.notifications = notifications
        self.sleeper = sleeper
        self.cleanupInterval = cleanupInterval
        defaultScope = Scope(rawValue: 0)
        states = [defaultScope: State(activeGeneration: nil)]
    }

    func makeScope() -> Scope {
        let scope = Scope(rawValue: nextScopeID)
        nextScopeID &+= 1
        states[scope] = State(activeGeneration: nil)
        return scope
    }

    var pendingIdentifierCount: Int {
        pendingIdentifierCount(for: defaultScope)
    }

    func pendingIdentifierCount(for scope: Scope) -> Int {
        states[scope]?.pendingIdentifiers.count ?? 0
    }

    var isCleanupMonitorRunning: Bool {
        cleanupTask != nil
    }

    func activate(generation: UInt64) {
        activate(generation: generation, scope: defaultScope)
    }

    func activate(generation: UInt64, scope: Scope) {
        states[scope, default: State(activeGeneration: nil)].activeGeneration = generation
    }

    @discardableResult
    func schedule(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger? = nil,
        fallbackContent: UNNotificationContent? = nil,
        generation: UInt64
    ) async -> Bool {
        await schedule(
            identifier: identifier,
            content: content,
            trigger: trigger,
            fallbackContent: fallbackContent,
            generation: generation,
            scope: defaultScope
        )
    }

    @discardableResult
    func schedule(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger? = nil,
        fallbackContent: UNNotificationContent? = nil,
        generation: UInt64,
        scope: Scope
    ) async -> Bool {
        guard isCurrent(generation, scope: scope) else { return false }
        var state = states[scope, default: State(activeGeneration: nil)]
        if state.pendingIdentifiers.insert(identifier).inserted {
            state.pendingRevision &+= 1
        }
        if state.inFlightIdentifiers.insert(identifier).inserted {
            state.pendingRevision &+= 1
        }
        states[scope] = state

        do {
            do {
                try await notifications.add(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: trigger
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard let fallbackContent else { throw error }
                guard isCurrent(generation, scope: scope) else { throw CancellationError() }
                try await notifications.add(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: fallbackContent,
                        trigger: trigger
                    )
                )
            }

            guard isCurrent(generation, scope: scope) else {
                removeScheduledNotification(identifier: identifier, scope: scope)
                return false
            }
            guard var current = states[scope] else { return false }
            current.inFlightIdentifiers.remove(identifier)
            current.pendingIdentifiers.insert(identifier)
            current.pendingRevision &+= 1
            states[scope] = current
            ensureCleanupMonitor()
            return true
        } catch {
            removeScheduledNotification(identifier: identifier, includingDelivered: false, scope: scope)
            return false
        }
    }

    func removeScheduledNotification(
        identifier: String,
        includingDelivered: Bool = true
    ) {
        removeScheduledNotification(
            identifier: identifier,
            includingDelivered: includingDelivered,
            scope: defaultScope
        )
    }

    func removeScheduledNotification(
        identifier: String,
        includingDelivered: Bool = true,
        scope: Scope
    ) {
        notifications.removePending([identifier])
        if includingDelivered {
            notifications.removeDelivered([identifier])
        }
        guard var state = states[scope] else { return }
        state.inFlightIdentifiers.remove(identifier)
        state.pendingIdentifiers.remove(identifier)
        state.pendingRevision &+= 1
        states[scope] = state
        stopCleanupMonitorIfIdle()
    }

    func cancel() {
        cancel(scope: defaultScope)
    }

    func cancel(scope: Scope) {
        guard var state = states[scope] else { return }
        let identifiers = Array(state.pendingIdentifiers)
        state.activeGeneration = nil
        state.pendingIdentifiers.removeAll()
        state.inFlightIdentifiers.removeAll()
        state.pendingRevision &+= 1
        states[scope] = state
        if !identifiers.isEmpty {
            notifications.removePending(identifiers)
        }
        stopCleanupMonitorIfIdle()
    }

    func reconcilePendingNotifications() async {
        await reconcilePendingNotifications(for: defaultScope)
    }

    func reconcilePendingNotifications(for scope: Scope) async {
        guard let state = states[scope], !state.pendingIdentifiers.isEmpty else { return }
        let requestedRevision = state.pendingRevision
        let systemPending = await notifications.pendingIdentifiers()
        guard !Task.isCancelled,
              var current = states[scope],
              current.pendingRevision == requestedRevision else {
            return
        }
        let previousCount = current.pendingIdentifiers.count
        current.pendingIdentifiers.formIntersection(systemPending.union(current.inFlightIdentifiers))
        if current.pendingIdentifiers.count != previousCount {
            current.pendingRevision &+= 1
        }
        states[scope] = current
        stopCleanupMonitorIfIdle()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        isCurrent(generation, scope: defaultScope)
    }

    func isCurrent(_ generation: UInt64, scope: Scope) -> Bool {
        !Task.isCancelled && states[scope]?.activeGeneration == generation
    }

    private var hasPendingEntries: Bool {
        states.values.contains { !$0.pendingIdentifiers.isEmpty }
    }

    private func stopCleanupMonitorIfIdle() {
        guard !hasPendingEntries else { return }
        cleanupGeneration &+= 1
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    private func ensureCleanupMonitor() {
        guard cleanupTask == nil, hasPendingEntries else { return }
        cleanupGeneration &+= 1
        let requestedGeneration = cleanupGeneration
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if cleanupGeneration == requestedGeneration {
                    cleanupTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(cleanupInterval)
                } catch {
                    return
                }
                guard cleanupGeneration == requestedGeneration, !Task.isCancelled else { return }
                await reconcileAllPendingNotifications()
                if !hasPendingEntries { return }
            }
        }
    }

    private func reconcileAllPendingNotifications() async {
        let scopes = states.compactMap { scope, state in
            state.pendingIdentifiers.isEmpty ? nil : scope
        }
        for scope in scopes {
            await reconcilePendingNotifications(for: scope)
        }
    }
}
