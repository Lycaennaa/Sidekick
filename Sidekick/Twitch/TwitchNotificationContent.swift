import Foundation
import Intents
import UserNotifications

enum TwitchNotificationContent {
    static func test() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Twitch notification test"
        content.subtitle = "Twitch"
        content.body = "Test notifications are working."
        content.sound = .default
        return content
    }

    static func base(for stream: TwitchFollowedStream) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = stream.notificationTitle
        content.subtitle = stream.notificationSubtitle
        content.body = stream.notificationBody
        content.sound = .default
        content.userInfo = [
            "twitch_stream_id": stream.id,
            "twitch_user_login": stream.userLogin
        ]
        return content
    }
    static func profileTest(for payload: TwitchProfileTestPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Twitch profile picture test"
        content.subtitle = payload.displayName
        content.body = "Profile picture test notification."
        content.sound = .default
        content.userInfo = [
            "twitch_profile_id": payload.userID,
            "twitch_user_login": payload.userLogin
        ]
        return content
    }

    static func withProfileImage(
        _ content: UNMutableNotificationContent,
        stream: TwitchFollowedStream,
        profileImageData: Data?
    ) -> (content: UNNotificationContent, hasAvatar: Bool) {
        withProfileImage(
            content,
            userID: stream.userID,
            displayName: stream.userName,
            profileImageData: profileImageData,
            conversationIdentifier: "twitch:\(stream.userID)"
        )
    }

    static func withProfileImage(
        _ content: UNMutableNotificationContent,
        profileTest: TwitchProfileTestPayload
    ) -> (content: UNNotificationContent, hasAvatar: Bool) {
        withProfileImage(
            content,
            userID: profileTest.userID,
            displayName: profileTest.displayName,
            profileImageData: profileTest.imageData,
            conversationIdentifier: "twitch-profile-test:\(profileTest.userID)"
        )
    }

    private static func withProfileImage(
        _ content: UNMutableNotificationContent,
        userID: String,
        displayName: String,
        profileImageData: Data?,
        conversationIdentifier: String
    ) -> (content: UNNotificationContent, hasAvatar: Bool) {
        guard let profileImageData else { return (content, false) }
        let sender = INPerson(
            personHandle: INPersonHandle(value: userID, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: INImage(imageData: profileImageData),
            contactIdentifier: nil,
            customIdentifier: "twitch:\(userID)"
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: conversationIdentifier,
            serviceName: "Twitch",
            sender: sender,
            attachments: nil
        )
        guard let updatedContent = try? content.updating(from: intent) else {
            return (content, false)
        }
        return (updatedContent, true)
    }
}
