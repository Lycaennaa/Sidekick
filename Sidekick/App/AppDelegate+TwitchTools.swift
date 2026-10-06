import AppKit

extension AppDelegate {
    private static let twitchToastDuration: TimeInterval = 10

    func presentTwitchToast(
        for stream: TwitchFollowedStream,
        profileImageData: Data?
    ) {
        let icon = profileImageData.flatMap(NSImage.init(data:))
            ?? NSImage(
                systemSymbolName: "person.crop.circle.fill",
                accessibilityDescription: "Twitch profile image"
            )
        toastPresentationCoordinator?.presentTwitch(
            ToastModel(
                generation: utilityToastGeneration,
                presentationStyle: .generic,
                summary: stream.notificationTitle,
                detail: stream.notificationBody,
                icon: icon,
                footer: stream.notificationSubtitle
            ),
            duration: Self.twitchToastDuration
        )
    }
    func presentTwitchProfileTest(_ payload: TwitchProfileTestPayload) {
        let icon = payload.imageData.flatMap(NSImage.init(data:))
            ?? NSImage(
                systemSymbolName: "person.crop.circle.fill",
                accessibilityDescription: "Twitch profile image"
            )
        toastPresentationCoordinator?.presentTwitch(
            ToastModel(
                generation: utilityToastGeneration,
                presentationStyle: .generic,
                summary: "Twitch profile picture test",
                detail: payload.displayName,
                icon: icon,
                footer: "Twitch"
            ),
            duration: Self.twitchToastDuration
        )
    }

    func presentTwitchSummaryToast(count: Int) {
        toastPresentationCoordinator?.presentTwitch(
            ToastModel(
                generation: utilityToastGeneration,
                presentationStyle: .generic,
                summary: "more followed channels are live",
                detail: "\(count) additional Twitch channels started streaming.",
                icon: NSImage(
                    systemSymbolName: "person.2.fill",
                    accessibilityDescription: "More Twitch channels are live"
                )
            ),
            duration: Self.twitchToastDuration
        )
    }
}
