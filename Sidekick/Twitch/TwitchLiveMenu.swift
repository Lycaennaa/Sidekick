import AppKit

@MainActor
final class TwitchLiveMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private var streams: [TwitchFollowedStream] = []
    private var isOpen = false
    var liveCount: Int {
        streams.count
    }

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild()
    }

    func refresh(_ streams: [TwitchFollowedStream]) {
        self.streams = streams
        if !isOpen {
            rebuild()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = true
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = false
    }

    private func rebuild() {
        menu.removeAllItems()

        let sortedStreams = streams.sorted { lhs, rhs in
            let lhsName = lhs.userName.isEmpty ? lhs.userLogin : lhs.userName
            let rhsName = rhs.userName.isEmpty ? rhs.userLogin : rhs.userName
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            let loginOrder = lhs.userLogin.localizedCaseInsensitiveCompare(rhs.userLogin)
            if loginOrder != .orderedSame {
                return loginOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }

        guard !sortedStreams.isEmpty else {
            let item = NSMenuItem(
                title: "No followed channels are live",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for stream in sortedStreams {
            let title = stream.userName.isEmpty ? stream.userLogin : stream.userName
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = true

            if !stream.title.isEmpty {
                item.toolTip = stream.title
            }
            menu.addItem(item)
        }
    }
}
