import Foundation

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
