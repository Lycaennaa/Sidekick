import Foundation
import XCTest

@MainActor
final class TwitchOAuthBrowserFallbackTests: XCTestCase {
    func testLegacyCallbackPageCompletesBrowserFallback() async throws {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "client-id",
            serverPort: 65433,
            requiredScopes: ["user:read:follows"],
            authorizationTimeout: 5
        )
        let firstBrowserOpened = expectation(description: "Override client ID opened")
        let secondBrowserOpened = expectation(description: "Default client ID opened")
        let completed = expectation(description: "Fallback authorization completed")
        var openedURLs: [URL] = []
        var result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        var completionCount = 0
        var duplicateResult: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        let fallback = TwitchOAuthBrowserFallback(configuration: configuration) { url in
            openedURLs.append(url)
            if openedURLs.count == 1 {
                firstBrowserOpened.fulfill()
            } else if openedURLs.count == 2 {
                secondBrowserOpened.fulfill()
            }
            return true
        }
        defer { fallback.cancel() }

        XCTAssertTrue(
            fallback.start(clientID: "runtime-client-id") { fallbackResult in
                result = fallbackResult
                completionCount += 1
                completed.fulfill()
            }
        )
        await fulfillment(of: [firstBrowserOpened], timeout: 1)
        XCTAssertFalse(fallback.start(clientID: "duplicate-client-id") { duplicateResult = $0 })
        XCTAssertEqual(duplicateResult, .failure(.alreadyInProgress))
        XCTAssertTrue(fallback.isActive)
        let authorizationURL = try XCTUnwrap(openedURLs.first)
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "client_id" })?.value,
            "runtime-client-id"
        )
        let state = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "state" })?.value)
        let redirectURI = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value)
        let responseStatus = try await completeBrowserCallback(
            redirectURI: redirectURI,
            state: state,
            token: "fallback-token"
        )
        XCTAssertEqual(responseStatus, 200)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(result, .success("fallback-token"))

        XCTAssertTrue(fallback.start { _ in })
        await fulfillment(of: [secondBrowserOpened], timeout: 1)
        let defaultURL = try XCTUnwrap(openedURLs.last)
        let defaultComponents = try XCTUnwrap(URLComponents(url: defaultURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            defaultComponents.queryItems?.first(where: { $0.name == "client_id" })?.value,
            "client-id"
        )
        fallback.cancel()
    }

    private func completeBrowserCallback(
        redirectURI: String,
        state: String,
        token: String
    ) async throws -> Int? {
        var pageComponents = URLComponents(string: redirectURI)
        pageComponents?.fragment = ""
        let (pageData, pageResponse) = try await URLSession.shared.data(
            from: XCTUnwrap(pageComponents?.url)
        )
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue((String(data: pageData, encoding: .utf8) ?? "").contains("Completing Twitch sign-in"))

        var callbackComponents = URLComponents(string: redirectURI)
        callbackComponents?.host = "127.0.0.1"
        callbackComponents?.path = "/token"
        var formComponents = URLComponents()
        formComponents.queryItems = [
            URLQueryItem(name: "token_type", value: "bearer"),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "scope", value: "user:read:follows"),
            URLQueryItem(name: "state", value: state)
        ]
        var request = URLRequest(url: try XCTUnwrap(callbackComponents?.url))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try XCTUnwrap(formComponents.percentEncodedQuery).utf8)
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    func testUnsetClientIDRejectsBrowserFallback() {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "none",
            serverPort: 65433,
            requiredScopes: ["user:read:follows"]
        )
        var result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        let fallback = TwitchOAuthBrowserFallback(configuration: configuration) { _ in
            XCTFail("Browser must not open without a client ID")
            return true
        }

        XCTAssertFalse(fallback.start { result = $0 })
        XCTAssertEqual(result, .failure(.invalidConfiguration))
        XCTAssertFalse(fallback.isActive)
    }
}
