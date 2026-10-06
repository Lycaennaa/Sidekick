import AppKit
import XCTest

@MainActor
final class TwitchLiveMenuTests: XCTestCase {
    func testRefreshShowsSortedLiveChannels() {
        let liveMenu = TwitchLiveMenu()
        liveMenu.refresh([
            makeStream(id: "z", login: "zed", name: "Zed"),
            makeStream(id: "a", login: "alpha", name: "Alpha")
        ])
        XCTAssertEqual(liveMenu.liveCount, 2)

        XCTAssertEqual(liveMenu.menu.items.map(\.title), ["Alpha", "Zed"])
        XCTAssertTrue(liveMenu.menu.items.allSatisfy(\.isEnabled))
        XCTAssertTrue(liveMenu.menu.items.allSatisfy { $0.view == nil })
        XCTAssertTrue(liveMenu.menu.items.allSatisfy { $0.action == nil })
    }

    func testEmptyMenuExplainsMissingLiveChannels() {
        let liveMenu = TwitchLiveMenu()
        XCTAssertEqual(liveMenu.liveCount, 0)

        XCTAssertEqual(liveMenu.menu.items.map(\.title), ["No followed channels are live"])
        XCTAssertFalse(liveMenu.menu.items[0].isEnabled)
    }

    private func makeStream(id: String, login: String, name: String) -> TwitchFollowedStream {
        TwitchFollowedStream(
            id: id,
            userID: id,
            userLogin: login,
            userName: name,
            title: "Live now",
            gameName: "Just Chatting"
        )
    }
}
