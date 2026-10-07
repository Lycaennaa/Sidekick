@preconcurrency import UserNotifications
import XCTest

final class TwitchNotificationModelsTests: XCTestCase {
    func testFirstPollDoesNotNotifyExistingLiveStreams() {
        let stream = makeStream(id: "stream-1")

        XCTAssertTrue(
            TwitchNotificationState.newlyLiveStreams(
                currentStreams: [stream],
                previousStreamIDs: nil
            ).isEmpty
        )
    }

    func testOnlyNewStreamIDsProduceNotifications() {
        let existing = makeStream(id: "stream-1")
        let new = makeStream(id: "stream-2")

        XCTAssertEqual(
            TwitchNotificationState.newlyLiveStreams(
                currentStreams: [existing, new],
                previousStreamIDs: [existing.id]
            ),
            [new]
        )
    }

    func testNotificationChannelModesIncludeAndExcludeCheckedChannels() {
        let checkedIDs: Set<String> = ["channel-1"]

        XCTAssertTrue(TwitchNotificationChannelMode.all.includes(
            channelID: "channel-1",
            selectedChannelIDs: checkedIDs
        ))
        XCTAssertTrue(TwitchNotificationChannelMode.all.includes(
            channelID: "channel-2",
            selectedChannelIDs: checkedIDs
        ))
        XCTAssertFalse(TwitchNotificationChannelMode.allExceptSelected.includes(
            channelID: "channel-1",
            selectedChannelIDs: checkedIDs
        ))
        XCTAssertTrue(TwitchNotificationChannelMode.allExceptSelected.includes(
            channelID: "channel-2",
            selectedChannelIDs: checkedIDs
        ))
        XCTAssertTrue(TwitchNotificationChannelMode.onlySelected.includes(
            channelID: "channel-1",
            selectedChannelIDs: checkedIDs
        ))
        XCTAssertFalse(TwitchNotificationChannelMode.onlySelected.includes(
            channelID: "channel-2",
            selectedChannelIDs: checkedIDs
        ))
    }

    func testLocalFollowedChannelSearchMatchesFuzzyNamesAndLogins() {
        let channel = TwitchFollowedChannel(id: "id", login: "alpha_gamer", name: "Fúzzy Channel")
        let channels = [channel]

        XCTAssertEqual(TwitchFollowedChannelSearch.filter(channels, query: "fzch"), [channel])
        XCTAssertEqual(TwitchFollowedChannelSearch.filter(channels, query: "AG"), [channel])
        XCTAssertEqual(TwitchFollowedChannelSearch.filter(channels, query: "  "), channels)
        XCTAssertTrue(TwitchFollowedChannelSearch.filter(channels, query: "unmatched").isEmpty)
    }

    func testFollowedChannelDirectoryRetainsLastListAfterRefreshFailure() {
        var directory = TwitchFollowedChannelDirectory()
        let channels = [
            TwitchFollowedChannel(id: "b", login: "second", name: "Second"),
            TwitchFollowedChannel(id: "a", login: "first", name: "First")
        ]

        XCTAssertTrue(directory.update(nil))
        XCTAssertTrue(directory.hasFailed)
        XCTAssertFalse(directory.hasLoaded)
        XCTAssertTrue(directory.update(channels))
        XCTAssertTrue(directory.hasLoaded)
        XCTAssertFalse(directory.hasFailed)
        XCTAssertEqual(directory.channels.map(\.id), ["a", "b"])
        XCTAssertTrue(directory.update(nil))
        XCTAssertTrue(directory.hasLoaded)
        XCTAssertTrue(directory.hasFailed)
        XCTAssertEqual(directory.channels.map(\.id), ["a", "b"])
        XCTAssertFalse(directory.update(nil))
        XCTAssertTrue(directory.reset())
        XCTAssertEqual(directory.state, .waiting)
    }

    func testOAuthPrefixAndWhitespaceAreNormalized() {
        XCTAssertEqual(TwitchOAuthToken.normalized("  OAuth:abc123\n"), "abc123")
        XCTAssertEqual(TwitchOAuthToken.normalized("  abc123  "), "abc123")
    }

    func testTwitchUsernameNormalizationRejectsInvalidInput() {
        XCTAssertEqual(TwitchUsername.normalized("  Some_User  "), "some_user")
        XCTAssertEqual(TwitchUsername.normalized("name with spaces"), "")
        XCTAssertEqual(TwitchUsername.normalized("name-with-dash"), "")
        XCTAssertEqual(TwitchUsername.normalized(String(repeating: "a", count: 26)), "")
    }

    func testNotificationContentMatchesToastAndSystemNotificationFields() {
        let stream = makeStream(id: "stream-1")

        XCTAssertEqual(stream.notificationTitle, "Channel is live")
        XCTAssertEqual(stream.notificationSubtitle, "Just Chatting")
        XCTAssertEqual(stream.notificationBody, "Live now")
    }

    func testNotificationBodyFallsBackWhenStreamTitleIsEmpty() {
        let stream = TwitchFollowedStream(
            id: "stream-1",
            userID: "user-1",
            userLogin: "channel",
            userName: "Channel",
            title: "",
            gameName: ""
        )

        XCTAssertEqual(stream.notificationSubtitle, "Twitch")
        XCTAssertEqual(stream.notificationBody, "started streaming on Twitch.")
    }

    func testProfileTestContentDoesNotClaimLiveStream() {
        let payload = TwitchProfileTestPayload(
            userID: "profile-id",
            userLogin: "profile_login",
            displayName: "Profile Name",
            imageData: nil
        )
        let content = TwitchNotificationContent.profileTest(for: payload)

        XCTAssertEqual(content.title, "Twitch profile picture test")
        XCTAssertEqual(content.subtitle, "Profile Name")
        XCTAssertEqual(content.body, "Profile picture test notification.")
        XCTAssertNil(content.userInfo["twitch_stream_id"])
        XCTAssertEqual(content.userInfo["twitch_profile_id"] as? String, "profile-id")
        XCTAssertFalse(content.title.contains("is live"))
    }

    func testTwitchResponseKeysDecode() throws {
        let data = Data("""
        {
          "data": [{
            "id": "stream-1",
            "user_id": "user-1",
            "user_login": "channel",
            "user_name": "Channel",
            "title": "Live now",
            "game_name": "Just Chatting"
          }],
          "pagination": {"cursor": "next-page"}
        }
        """.utf8)

        let page = try JSONDecoder().decode(TwitchStreamsPage.self, from: data)

        XCTAssertEqual(page.data.first?.userID, "user-1")
        XCTAssertEqual(page.data.first?.gameName, "Just Chatting")
        XCTAssertEqual(page.pagination?.cursor, "next-page")
    }

    func testTwitchUserProfileImageKeyDecodes() throws {
        let data = Data("""
        {"data":[{"id":"user-1","login":"channel","display_name":"Channel","profile_image_url":"https://static-cdn.jtvnw.net/avatar.png"}]}
        """.utf8)

        let page = try JSONDecoder().decode(TwitchUsersPage.self, from: data)

        XCTAssertEqual(page.data.first?.id, "user-1")
        XCTAssertEqual(page.data.first?.login, "channel")
        XCTAssertEqual(page.data.first?.displayName, "Channel")
        XCTAssertEqual(
            page.data.first?.profileImageURL,
            "https://static-cdn.jtvnw.net/avatar.png"
        )
    }

    private func makeStream(id: String) -> TwitchFollowedStream {
        TwitchFollowedStream(
            id: id,
            userID: "user-1",
            userLogin: "channel",
            userName: "Channel",
            title: "Live now",
            gameName: "Just Chatting"
        )
    }
}
