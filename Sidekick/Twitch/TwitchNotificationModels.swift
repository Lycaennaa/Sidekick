import Foundation

enum TwitchNotificationChannelMode: String, CaseIterable, Equatable, Sendable {
    case all
    case allExceptSelected
    case onlySelected

    var title: String {
        switch self {
        case .all:
            "All followed channels"
        case .allExceptSelected:
            "All except checked channels"
        case .onlySelected:
            "Only checked channels"
        }
    }

    func includes(channelID: String, selectedChannelIDs: Set<String>) -> Bool {
        switch self {
        case .all:
            true
        case .allExceptSelected:
            !selectedChannelIDs.contains(channelID)
        case .onlySelected:
            selectedChannelIDs.contains(channelID)
        }
    }
}
struct TwitchFollowedStream: Codable, Equatable, Sendable {
    let id: String
    let userID: String
    let userLogin: String
    let userName: String
    let title: String
    let gameName: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case userLogin = "user_login"
        case userName = "user_name"
        case title
        case gameName = "game_name"
    }
    var notificationTitle: String {
        "\(userName) is live"
    }

    var notificationSubtitle: String {
        gameName.isEmpty ? "Twitch" : gameName
    }

    var notificationBody: String {
        title.isEmpty ? "started streaming on Twitch." : title
    }
}

struct TwitchFollowedChannel: Codable, Equatable, Sendable {
    let id: String
    let login: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "broadcaster_id"
        case login = "broadcaster_login"
        case name = "broadcaster_name"
    }
}

struct TwitchFollowedChannelsPage: Codable, Sendable {
    let data: [TwitchFollowedChannel]
    let pagination: TwitchPagination?
}

enum TwitchFollowedChannelSearch {
    static func filter(
        _ channels: [TwitchFollowedChannel],
        query: String
    ) -> [TwitchFollowedChannel] {
        let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalizedQuery.isEmpty else { return channels }
        return channels.filter {
            matches(normalizedQuery, in: normalize($0.name))
                || matches(normalizedQuery, in: normalize($0.login))
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func matches(_ query: String, in candidate: String) -> Bool {
        var queryIndex = query.startIndex
        for character in candidate {
            guard query[queryIndex] == character else { continue }
            queryIndex = query.index(after: queryIndex)
            if queryIndex == query.endIndex { return true }
        }
        return false
    }
}

struct TwitchFollowedChannelDirectory: Sendable {
    enum State: Equatable, Sendable {
        case waiting
        case loaded([TwitchFollowedChannel])
        case failed
        case refreshFailed([TwitchFollowedChannel])
    }

    private(set) var state: State = .waiting

    var channels: [TwitchFollowedChannel] {
        switch state {
        case .loaded(let channels), .refreshFailed(let channels):
            channels
        case .waiting, .failed:
            []
        }
    }

    var hasLoaded: Bool {
        switch state {
        case .loaded, .refreshFailed:
            true
        case .waiting, .failed:
            false
        }
    }

    var hasFailed: Bool {
        switch state {
        case .failed, .refreshFailed:
            true
        case .waiting, .loaded:
            false
        }
    }

    mutating func update(_ channels: [TwitchFollowedChannel]?) -> Bool {
        let nextState: State
        if let channels {
            nextState = .loaded(channels.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            })
        } else {
            switch state {
            case .loaded(let channels), .refreshFailed(let channels):
                nextState = .refreshFailed(channels)
            case .waiting, .failed:
                nextState = .failed
            }
        }
        guard nextState != state else { return false }
        state = nextState
        return true
    }

    mutating func reset() -> Bool {
        guard state != .waiting else { return false }
        state = .waiting
        return true
    }
}

struct TwitchStreamsPage: Codable, Sendable {
    let data: [TwitchFollowedStream]
    let pagination: TwitchPagination?
}
struct TwitchUserProfile: Codable, Sendable {
    let id: String
    let login: String?
    let displayName: String?
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName = "display_name"
        case profileImageURL = "profile_image_url"
    }
}
struct TwitchProfileTestPayload: Equatable, Sendable {
    let userID: String
    let userLogin: String
    let displayName: String
    let imageData: Data?
}

struct TwitchUsersPage: Codable, Sendable {
    let data: [TwitchUserProfile]
}

struct TwitchPagination: Codable, Sendable {
    let cursor: String?
}

struct TwitchTokenValidation: Codable, Equatable, Sendable {
    let clientID: String
    let login: String
    let scopes: [String]
    let userID: String

    var hasFollowedStreamsScope: Bool {
        scopes.contains("user:read:follows")
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case login
        case scopes
        case userID = "user_id"
    }
}

enum TwitchOAuthToken {
    static func normalized(_ rawToken: String) -> String {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("oauth:") {
            token.removeFirst("oauth:".count)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TwitchUsername {
    static func normalized(_ rawUsername: String) -> String {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard username.unicodeScalars.count <= 25,
              username.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              }) else {
            return ""
        }
        return username
    }
}

enum TwitchNotificationState {
    static func newlyLiveStreams(
        currentStreams: [TwitchFollowedStream],
        previousStreamIDs: Set<String>?
    ) -> [TwitchFollowedStream] {
        guard let previousStreamIDs else { return [] }
        return currentStreams.filter { !previousStreamIDs.contains($0.id) }
    }
}
