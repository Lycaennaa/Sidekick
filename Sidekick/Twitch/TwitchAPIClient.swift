import Foundation
import ImageIO

struct TwitchAPIClient: Sendable {
    static let pollInterval: TimeInterval = 150
    static let pageSize = 100
    static let maximumPages = 100
    static let maximumProfileImageBytes = 1_048_576
    static let maximumProfileImageDimension = 1024
    static let maximumProfileResponseBytes = 1_048_576
    static let maximumAPIResponseBytes = 4 * 1_048_576
    static let maximumConcurrentImageDownloads = 4
    static let maximumBufferedProfileImageResults = maximumConcurrentImageDownloads * 2
    static let maximumProfileImageAggregateBytes = maximumProfileImageBytes * maximumConcurrentImageDownloads
    static let maximumProfileImageUsers = maximumPages * pageSize
    static let profileImageRequestTimeout: TimeInterval = 10
    static let profileTestRequestTimeout: TimeInterval = 10

    struct Session: Sendable {
        let accessToken: String
        let clientID: String
        let userID: String
    }

    struct ProfileImageResult: Sendable {
        let userID: String
        let data: Data?
    }

    enum APIError: Error, Equatable, LocalizedError {
        case invalidResponse
        case invalidToken
        case missingFollowedStreamsScope
        case network
        case rateLimited
        case server(Int)
        case tooManyFollowedStreams
        case tooManyFollowedChannels
        case tooManyProfileImages
        case userNotFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "Twitch returned an invalid response."
            case .invalidToken:
                "The OAuth token is invalid or expired."
            case .missingFollowedStreamsScope:
                "The OAuth token needs the user:read:follows scope."
            case .network:
                "Could not reach Twitch."
            case .rateLimited:
                "Twitch API rate limit reached."
            case let .server(statusCode):
                "Twitch API returned HTTP \(statusCode)."
            case .tooManyFollowedStreams:
                "The followed-stream list is larger than the supported limit."
            case .tooManyFollowedChannels:
                "The followed-channel list is larger than the supported limit."
            case .tooManyProfileImages:
                "The profile-image request is larger than the supported limit."
            case .userNotFound:
                "Twitch user was not found."
            }
        }
    }

    private let apiSession: URLSession
    private let profileImageSession: URLSession
    private let profileTestSession: URLSession
    private let apiBaseURL: URL

    init(
        urlSession: URLSession = .shared,
        profileImageSession: URLSession? = nil,
        profileTestSession: URLSession? = nil,
        apiBaseURL: URL = URL(string: "https://api.twitch.tv")!
    ) {
        apiSession = urlSession
        self.profileImageSession = profileImageSession ?? Self.makeEphemeralSession(
            timeout: Self.profileImageRequestTimeout
        )
        self.profileTestSession = profileTestSession ?? Self.makeEphemeralSession(
            timeout: Self.profileTestRequestTimeout
        )
        self.apiBaseURL = apiBaseURL
    }

}

extension TwitchAPIClient {
    func authenticate(accessToken: String) async throws -> Session {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/validate") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        let validation: TwitchTokenValidation = try await perform(request, using: apiSession)
        guard validation.hasFollowedStreamsScope else {
            throw APIError.missingFollowedStreamsScope
        }
        return Session(
            accessToken: accessToken,
            clientID: validation.clientID,
            userID: validation.userID
        )
    }

    func followedStreams(for session: Session) async throws -> [TwitchFollowedStream] {
        try await followedPages(tooManyError: .tooManyFollowedStreams) { cursor in
            var components = apiURLComponents(path: "/helix/streams/followed")
            components?.queryItems = [
                URLQueryItem(name: "user_id", value: session.userID),
                URLQueryItem(name: "first", value: String(Self.pageSize))
            ]
            if let cursor {
                components?.queryItems?.append(URLQueryItem(name: "after", value: cursor))
            }
            guard let url = components?.url else { throw APIError.invalidResponse }

            let page: TwitchStreamsPage = try await perform(
                authorizedRequest(url: url, session: session),
                using: apiSession
            )
            return (data: page.data, cursor: page.pagination?.cursor)
        }
    }

    func followedChannels(for session: Session) async throws -> [TwitchFollowedChannel] {
        try await followedPages(tooManyError: .tooManyFollowedChannels) { cursor in
            var components = apiURLComponents(path: "/helix/channels/followed")
            components?.queryItems = [
                URLQueryItem(name: "user_id", value: session.userID),
                URLQueryItem(name: "first", value: String(Self.pageSize))
            ]
            if let cursor {
                components?.queryItems?.append(URLQueryItem(name: "after", value: cursor))
            }
            guard let url = components?.url else { throw APIError.invalidResponse }

            let page: TwitchFollowedChannelsPage = try await perform(
                authorizedRequest(url: url, session: session),
                using: apiSession
            )
            return (data: page.data, cursor: page.pagination?.cursor)
        }
    }

    private func followedPages<Element>(
        tooManyError: APIError,
        fetchPage: (String?) async throws -> (data: [Element], cursor: String?)
    ) async throws -> [Element] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var items: [Element] = []

        for _ in 0..<Self.maximumPages {
            try Task.checkCancellation()
            let page = try await fetchPage(cursor)
            try Task.checkCancellation()
            guard page.data.count <= Self.pageSize else {
                throw APIError.invalidResponse
            }
            guard items.count <= Self.maximumPages * Self.pageSize - page.data.count else {
                throw tooManyError
            }
            items.append(contentsOf: page.data)
            guard let nextCursor = page.cursor, !nextCursor.isEmpty else {
                return items
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw APIError.invalidResponse
            }
            cursor = nextCursor
        }
        throw tooManyError
    }

    private func apiURLComponents(path: String) -> URLComponents? {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components
    }

    func profileImageResults(
        for userIDs: [String],
        session: Session
    ) -> AsyncThrowingStream<ProfileImageResult, Error> {
        guard userIDs.count <= Self.maximumProfileImageUsers else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: APIError.tooManyProfileImages)
            }
        }
        let uniqueUserIDs = Array(Set(userIDs)).sorted()
        guard !uniqueUserIDs.isEmpty else {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedProfileImageResults)
        ) { continuation in
            let producer = Task {
                do {
                    let profiles = try await fetchProfiles(for: uniqueUserIDs, session: session)
                    for userID in uniqueUserIDs where profileImageURL(for: profiles[userID]) == nil {
                        try Task.checkCancellation()
                        try await Self.emitProfileImageResult(
                            ProfileImageResult(userID: userID, data: nil),
                            to: continuation
                        )
                    }

                    let downloads = uniqueUserIDs.compactMap { userID in
                        profileImageURL(for: profiles[userID]).map { (userID, $0) }
                    }
                    try await withThrowingTaskGroup(of: ProfileImageResult.self) { group in
                        var iterator = downloads.makeIterator()
                        func addNext() {
                            guard let (userID, url) = iterator.next() else { return }
                            group.addTask {
                                do {
                                    let data = try await downloadProfileImage(
                                        from: url,
                                        using: profileImageSession,
                                        timeoutInterval: Self.profileImageRequestTimeout
                                    )
                                    return ProfileImageResult(userID: userID, data: data)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return ProfileImageResult(userID: userID, data: nil)
                                }
                            }
                        }

                        for _ in 0..<min(Self.maximumConcurrentImageDownloads, downloads.count) {
                            addNext()
                        }
                        while let result = try await group.next() {
                            try await Self.emitProfileImageResult(result, to: continuation)
                            addNext()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func profileImageData(
        for userIDs: [String],
        session: Session
    ) async throws -> [String: Data] {
        var images: [String: Data] = [:]
        var aggregateBytes = 0
        for try await result in profileImageResults(for: userIDs, session: session) {
            // Results past the aggregate cap are treated as missing avatars.
            guard let data = result.data,
                  data.count <= Self.maximumProfileImageAggregateBytes - aggregateBytes else {
                continue
            }
            images[result.userID] = data
            aggregateBytes += data.count
        }
        return images
    }

    func profileImageData(
        forUsername username: String,
        session: Session
    ) async throws -> (profile: TwitchUserProfile, imageData: Data?) {
        var components = apiURLComponents(path: "/helix/users")
        components?.queryItems = [URLQueryItem(name: "login", value: username)]
        guard let url = components?.url else { throw APIError.invalidResponse }
        var request = authorizedRequest(url: url, session: session)
        request.timeoutInterval = Self.profileTestRequestTimeout
        let page: TwitchUsersPage = try await perform(
            request,
            using: profileTestSession,
            maximumBytes: Self.maximumProfileResponseBytes
        )
        guard let profile = page.data.first else { throw APIError.userNotFound }
        guard let imageURL = profileImageURL(for: profile) else { return (profile, nil) }

        do {
            return (
                profile,
                try await downloadProfileImage(
                    from: imageURL,
                    using: profileTestSession,
                    timeoutInterval: Self.profileTestRequestTimeout
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (profile, nil)
        }
    }

    private func fetchProfiles(
        for userIDs: [String],
        session: Session
    ) async throws -> [String: TwitchUserProfile] {
        let requestedUserIDs = Set(userIDs)
        var profiles: [String: TwitchUserProfile] = [:]
        for start in stride(from: 0, to: userIDs.count, by: Self.pageSize) {
            let end = min(start + Self.pageSize, userIDs.count)
            var components = apiURLComponents(path: "/helix/users")
            components?.queryItems = userIDs[start..<end].map {
                URLQueryItem(name: "id", value: $0)
            }
            guard let url = components?.url else { throw APIError.invalidResponse }
            var request = authorizedRequest(url: url, session: session)
            request.timeoutInterval = Self.profileImageRequestTimeout
            let page: TwitchUsersPage = try await perform(
                request,
                using: profileImageSession,
                maximumBytes: Self.maximumProfileResponseBytes
            )
            for profile in page.data where requestedUserIDs.contains(profile.id) {
                profiles[profile.id] = profile
            }
        }
        return profiles
    }

    private func profileImageURL(for profile: TwitchUserProfile?) -> URL? {
        guard let rawURL = profile?.profileImageURL,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

}

extension TwitchAPIClient {
    private func downloadProfileImage(
        from url: URL,
        using session: URLSession,
        timeoutInterval: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        let (data, response) = try await responseData(
            request,
            using: session,
            maximumBytes: Self.maximumProfileImageBytes
        )
        guard response.mimeType?.lowercased().hasPrefix("image/") == true,
              !data.isEmpty,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0,
              height.int64Value > 0,
              width.int64Value <= Int64(Self.maximumProfileImageDimension),
              height.int64Value <= Int64(Self.maximumProfileImageDimension),
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
            throw APIError.invalidResponse
        }
        return data
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        using session: URLSession,
        maximumBytes: Int = Self.maximumAPIResponseBytes
    ) async throws -> Response {
        let (data, _) = try await responseData(
            request,
            using: session,
            maximumBytes: maximumBytes
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func responseData(
        _ request: URLRequest,
        using session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: TwitchHTTPSRedirectDelegate()
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            try validate(httpResponse)

            var data = Data()
            data.reserveCapacity(min(maximumBytes, max(0, Int(httpResponse.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw APIError.invalidResponse }
                data.append(byte)
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401, 403:
                throw APIError.invalidToken
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.server(response.statusCode)
            }
        }
    }

    private func authorizedRequest(url: URL, session: Session) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(session.clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private static func emitProfileImageResult(
        _ result: ProfileImageResult,
        to continuation: AsyncThrowingStream<ProfileImageResult, Error>.Continuation
    ) async throws {
        // A full buffer retries the same result until the consumer makes room; termination cancels production.
        while true {
            switch continuation.yield(result) {
            case .enqueued:
                return
            case .dropped:
                try Task.checkCancellation()
                await Task.yield()
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}
private final class TwitchHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
