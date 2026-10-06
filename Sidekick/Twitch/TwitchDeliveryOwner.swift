import Foundation
import UserNotifications

@MainActor
final class TwitchDeliveryOwner {
    static let maximumIndividualNotifications = 100

    struct Dependencies: Sendable {
        let profileImages: @MainActor @Sendable (
            [String],
            TwitchAPIClient.Session
        ) -> AsyncThrowingStream<TwitchAPIClient.ProfileImageResult, Error>
        let notifications: TwitchNotificationCenterClient
        let sleeper: TwitchSleepClient
        let cleanupInterval: TimeInterval
    }

    enum Event: Sendable {
        case streamDelivered(TwitchFollowedStream, Data?)
        case summaryDelivered(Int)
        case schedulingFailed
    }

    private let dependencies: Dependencies
    private let scheduler: TwitchNotificationScheduler
    private let scope: TwitchNotificationScheduler.Scope

    init(
        dependencies: Dependencies,
        scheduler: TwitchNotificationScheduler? = nil
    ) {
        self.dependencies = dependencies
        let scheduler = scheduler ?? TwitchNotificationScheduler(
            notifications: dependencies.notifications,
            sleeper: dependencies.sleeper,
            cleanupInterval: dependencies.cleanupInterval
        )
        self.scheduler = scheduler
        scope = scheduler.makeScope()
    }

    var pendingIdentifierCount: Int {
        scheduler.pendingIdentifierCount(for: scope)
    }

    var isCleanupMonitorRunning: Bool {
        scheduler.isCleanupMonitorRunning
    }

    func activate(generation: UInt64) {
        scheduler.activate(generation: generation, scope: scope)
    }

    func deliver(
        streams: [TwitchFollowedStream],
        session: TwitchAPIClient.Session,
        generation: UInt64,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async -> Set<String> {
        guard !streams.isEmpty else { return [] }
        guard scheduler.isCurrent(generation, scope: scope) else { return [] }

        let individualStreams = Array(streams.prefix(Self.maximumIndividualNotifications))
        var failedIDs = await deliverIndividuals(
            individualStreams,
            session: session,
            generation: generation,
            onEvent: onEvent
        )

        guard streams.count > Self.maximumIndividualNotifications,
              scheduler.isCurrent(generation, scope: scope) else {
            return failedIDs
        }
        let remainingStreams = Array(streams.dropFirst(Self.maximumIndividualNotifications))
        let content = UNMutableNotificationContent()
        content.title = "more followed channels are live"
        content.body = "\(remainingStreams.count) additional Twitch channels started streaming."
        content.sound = .default
        let identifier = "twitch-stream-summary-\(generation)"

        if await scheduler.schedule(
            identifier: identifier,
            content: content,
            generation: generation,
            scope: scope
        ) {
            guard scheduler.isCurrent(generation, scope: scope) else { return failedIDs }
            onEvent(.summaryDelivered(remainingStreams.count))
        } else if scheduler.isCurrent(generation, scope: scope) {
            failedIDs.formUnion(remainingStreams.map(\.id))
            onEvent(.schedulingFailed)
        }
        return failedIDs
    }

    func cancel() {
        scheduler.cancel(scope: scope)
    }

    func reconcilePendingNotifications() async {
        await scheduler.reconcilePendingNotifications(for: scope)
    }

    private func deliverIndividuals(
        _ streams: [TwitchFollowedStream],
        session: TwitchAPIClient.Session,
        generation: UInt64,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) async -> Set<String> {
        var streamsByUserID = Dictionary(grouping: streams, by: \.userID)
        var failedIDs: Set<String> = []

        do {
            let results = dependencies.profileImages(
                Array(streamsByUserID.keys),
                session
            )
            for try await result in results {
                guard scheduler.isCurrent(generation, scope: scope) else { return failedIDs }
                let matchingStreams = streamsByUserID.removeValue(forKey: result.userID) ?? []
                await schedule(
                    matchingStreams,
                    imageData: result.data,
                    generation: generation,
                    failedIDs: &failedIDs,
                    onEvent: onEvent
                )
            }
        } catch is CancellationError {
            return failedIDs
        } catch {
            guard scheduler.isCurrent(generation, scope: scope) else { return failedIDs }
        }

        for remainingStreams in streamsByUserID.values {
            await schedule(
                remainingStreams,
                imageData: nil,
                generation: generation,
                failedIDs: &failedIDs,
                onEvent: onEvent
            )
        }
        return failedIDs
    }

    private func schedule(
        _ streams: [TwitchFollowedStream],
        imageData: Data?,
        generation: UInt64,
        failedIDs: inout Set<String>,
        onEvent: @MainActor @Sendable (Event) -> Void
    ) async {
        for stream in streams {
            guard scheduler.isCurrent(generation, scope: scope) else { return }
            let baseContent = TwitchNotificationContent.base(for: stream)
            let personalized = TwitchNotificationContent.withProfileImage(
                baseContent,
                stream: stream,
                profileImageData: imageData
            )
            let identifier = "twitch-stream-\(generation)-\(stream.id)"
            if await scheduler.schedule(
                identifier: identifier,
                content: personalized.content,
                fallbackContent: personalized.hasAvatar ? baseContent : nil,
                generation: generation,
                scope: scope
            ) {
                guard scheduler.isCurrent(generation, scope: scope) else { return }
                onEvent(.streamDelivered(stream, imageData))
            } else if scheduler.isCurrent(generation, scope: scope) {
                failedIDs.insert(stream.id)
                onEvent(.schedulingFailed)
            }
        }
    }
}
