import Foundation
import XCTest

final class TwitchAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testProfileMetadataRequestsUseAtMostOneHundredIDs() async throws {
        StubURLProtocol.handler = { request in
            let ids = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name == "id" }.compactMap(\.value) ?? []
            StubURLProtocol.recordBatch(ids.count)
            let profiles = ids.map { ["id": $0] }
            return .json(try JSONSerialization.data(withJSONObject: ["data": profiles]))
        }
        let client = makeClient()
        let ids = (0..<101).map { "user-\($0)" }

        var results: [TwitchAPIClient.ProfileImageResult] = []
        for try await result in client.profileImageResults(for: ids, session: session) {
            results.append(result)
        }

        XCTAssertEqual(StubURLProtocol.batchSizes, [100, 1])
        XCTAssertEqual(Set(results.map(\.userID)), Set(ids))
        XCTAssertTrue(results.allSatisfy { $0.data == nil })
    }

    func testProfileImageRequestRejectsExcessiveUserIDs() async {
        let client = makeClient()
        let ids = (0...TwitchAPIClient.maximumProfileImageUsers).map { "user-\($0)" }

        do {
            for try await _ in client.profileImageResults(for: ids, session: session) {}
            XCTFail("Expected the profile-image request to be bounded")
        } catch let error as TwitchAPIClient.APIError {
            XCTAssertEqual(error, .tooManyProfileImages)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImageDownloadsAreBoundedAndPartialFailuresAreStreamed() async throws {
        let imageData = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+" +
                    "A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "api.twitch.tv" {
                let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .filter { $0.name == "id" }.compactMap(\.value) ?? []
                let profiles = ids.map {
                    ["id": $0, "profile_image_url": "https://images.test/\($0).png"]
                }
                return .json(try JSONSerialization.data(withJSONObject: ["data": profiles]))
            }
            if url.lastPathComponent == "user-2.png" {
                return .init(statusCode: 500, mimeType: "text/plain", data: Data(), delay: 0.03)
            }
            return .init(statusCode: 200, mimeType: "image/png", data: imageData, delay: 0.03)
        }
        let client = makeClient()
        let ids = (0..<8).map { "user-\($0)" }

        var results: [String: Data?] = [:]
        for try await result in client.profileImageResults(for: ids, session: session) {
            results[result.userID] = result.data
        }

        XCTAssertEqual(results.count, ids.count)
        let failedImageData = try XCTUnwrap(results["user-2"])
        XCTAssertNil(failedImageData)
        XCTAssertEqual(results.values.compactMap(\.self).count, ids.count - 1)
        XCTAssertEqual(StubURLProtocol.maximumActiveImageRequests, 4)
    }

    func testCancellingImageResultConsumerCancelsInFlightRequests() async throws {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "api.twitch.tv" {
                let profiles = (0..<8).map {
                    ["id": "user-\($0)", "profile_image_url": "https://images.test/user-\($0).png"]
                }
                return .json(try JSONSerialization.data(withJSONObject: ["data": profiles]))
            }
            return .init(statusCode: 200, mimeType: "image/png", data: Data([0]), delay: 5)
        }
        let client = makeClient()
        let stream = client.profileImageResults(
            for: (0..<8).map { "user-\($0)" },
            session: session
        )
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }
        await eventually { StubURLProtocol.activeImageRequests == 4 }

        consumer.cancel()
        _ = await consumer.result
        await eventually { StubURLProtocol.activeImageRequests == 0 }

        XCTAssertGreaterThanOrEqual(StubURLProtocol.cancelledRequestCount, 4)
    }

    func testFollowedStreamsPaginatesAndRejectsOversizedResponses() async throws {
        StubURLProtocol.handler = { request in
            let components = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "first" })?.value, "100")
            if components?.queryItems?.contains(where: { $0.name == "after" }) == true {
                return .json(Data(#"{"data":[],"pagination":{}}"#.utf8))
            }
            return .json(
                Data(
                    #"""
                    {
                      "data": [{
                        "id": "stream",
                        "user_id": "user",
                        "user_login": "login",
                        "user_name": "name",
                        "title": "title",
                        "game_name": "game"
                      }],
                      "pagination": {"cursor": "next"}
                    }
                    """#.utf8
                )
            )
        }
        let client = makeClient()
        let followedStreamIDs = try await client.followedStreams(for: session).map(\.id)
        XCTAssertEqual(followedStreamIDs, ["stream"])

        StubURLProtocol.handler = { _ in
            .json(Data(repeating: 0x20, count: TwitchAPIClient.maximumProfileResponseBytes + 1))
        }
        do {
            for try await _ in client.profileImageResults(for: ["user"], session: session) {}
            XCTFail("Expected response limit rejection")
        } catch let error as TwitchAPIClient.APIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testFollowedStreamsRejectsPageLargerThanConfiguredPageSize() async throws {
        StubURLProtocol.handler = { _ in
            let page = (0...TwitchAPIClient.pageSize).map { index in
                [
                    "id": "stream-\(index)",
                    "user_id": "user-\(index)",
                    "user_login": "login-\(index)",
                    "user_name": "name-\(index)",
                    "title": "title-\(index)",
                    "game_name": "game-\(index)"
                ]
            }
            return .json(try JSONSerialization.data(withJSONObject: ["data": page]))
        }

        let client = makeClient()
        do {
            _ = try await client.followedStreams(for: session)
            XCTFail("Expected an oversized page to be rejected")
        } catch let error as TwitchAPIClient.APIError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    private var session: TwitchAPIClient.Session {
        .init(accessToken: "token", clientID: "client", userID: "user")
    }

    private func makeClient() -> TwitchAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return TwitchAPIClient(
            urlSession: session,
            profileImageSession: session,
            profileTestSession: session
        )
    }

    private func eventually(
        _ predicate: @escaping @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let mimeType: String
        let data: Data
        let delay: TimeInterval

        static func json(_ data: Data) -> Stub {
            Stub(statusCode: 200, mimeType: "application/json", data: data, delay: 0)
        }
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Stub)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var batches: [Int] = []
    nonisolated(unsafe) private static var activeImages = 0
    nonisolated(unsafe) private static var maximumActiveImages = 0
    nonisolated(unsafe) private static var cancellations = 0

    private let stateLock = NSLock()
    private var workItem: DispatchWorkItem?
    private var countedImage = false
    private var completed = false

    static var batchSizes: [Int] { lock.withLock { batches } }
    static var activeImageRequests: Int { lock.withLock { activeImages } }
    static var maximumActiveImageRequests: Int { lock.withLock { maximumActiveImages } }
    static var cancelledRequestCount: Int { lock.withLock { cancellations } }

    static func reset() {
        lock.withLock {
            batches = []
            activeImages = 0
            maximumActiveImages = 0
            cancellations = 0
        }
        handler = nil
    }

    static func recordBatch(_ size: Int) {
        lock.withLock { batches.append(size) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let stub = try XCTUnwrap(Self.handler)(request)
            let isImage = request.url?.host == "images.test"
            if isImage {
                stateLock.withLock { countedImage = true }
                Self.lock.withLock {
                    Self.activeImages += 1
                    Self.maximumActiveImages = max(Self.maximumActiveImages, Self.activeImages)
                }
            }
            let work = DispatchWorkItem { [weak self] in self?.complete(with: stub) }
            stateLock.withLock { workItem = work }
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: work)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let shouldCancel = stateLock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            workItem?.cancel()
            return countedImage
        }
        if shouldCancel {
            Self.lock.withLock {
                Self.activeImages -= 1
                Self.cancellations += 1
            }
        }
    }

    private func complete(with stub: Stub) {
        let shouldComplete = stateLock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldComplete, let url = request.url else { return }
        if countedImage {
            Self.lock.withLock { Self.activeImages -= 1 }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.mimeType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
