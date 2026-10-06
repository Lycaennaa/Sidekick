import Foundation
import WebKit
import XCTest

@MainActor
final class TwitchOAuthAuthorizationTests: XCTestCase {
    func testDefaultConfigurationUsesCentralClientAndRedirect() {
        let configuration = TwitchOAuthAuthorization.Configuration.appDefault

        XCTAssertEqual(configuration.clientID, TwitchOAuthConfiguration.effectiveClientID)
        XCTAssertEqual(configuration.redirectURI, "http://localhost:65432/redirect")
        XCTAssertEqual(configuration.requiredScopes, ["user:read:follows"])
    }

    func testClientIDUsesInAppAndBuildTimeValuesAndDefaultsToNone() {
        XCTAssertEqual(
            TwitchOAuthConfiguration.resolveClientID(
                userOverride: "in-app-id",
                appClientID: "build-time-id"
            ),
            "in-app-id"
        )
        XCTAssertEqual(
            TwitchOAuthConfiguration.resolveClientID(
                userOverride: " none ",
                appClientID: " build-time-id "
            ),
            "build-time-id"
        )
        XCTAssertEqual(
            TwitchOAuthConfiguration.resolveClientID(
                userOverride: nil,
                appClientID: "none"
            ),
            "none"
        )
        XCTAssertEqual(
            TwitchOAuthConfiguration.resolveClientID(
                userOverride: nil,
                appClientID: nil
            ),
            "none"
        )
    }

    func testConfiguredClientBuildsAuthorizationURL() throws {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "test-client-id",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )
        let url = try XCTUnwrap(
            TwitchOAuthAuthorization.authorizationURL(
                configuration: configuration,
                state: "state-value"
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(values["client_id"], "test-client-id")
        XCTAssertEqual(values["redirect_uri"], configuration.redirectURI)
        XCTAssertEqual(values["response_type"], "token")
        XCTAssertEqual(values["scope"], "user:read:follows")
        XCTAssertEqual(values["state"], "state-value")
    }

    func testUnsetClientIDIsRejected() {
        XCTAssertFalse(TwitchOAuthConfiguration.isConfigured(""))
        XCTAssertFalse(TwitchOAuthConfiguration.isConfigured("none"))
        XCTAssertFalse(TwitchOAuthConfiguration.isConfigured(" NONE "))
        XCTAssertTrue(TwitchOAuthConfiguration.isConfigured("test-client-id"))

        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "none",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )
        XCTAssertNil(
            TwitchOAuthAuthorization.authorizationURL(configuration: configuration, state: "state")
        )
    }

    func testAuthorizationRejectsUnsetClientID() {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "none",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )
        var result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        let authorization = TwitchOAuthAuthorization(configuration: configuration)

        XCTAssertFalse(authorization.start { result = $0 })
        XCTAssertEqual(result, .failure(.invalidConfiguration))
        XCTAssertFalse(authorization.isActive)
    }

    func testConfiguredAuthorizationCreatesRealWebView() async {
        let windowPresented = expectation(description: "OAuth window presented")
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "test-client-id",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )
        let authorization = TwitchOAuthAuthorization(
            configuration: configuration,
            presentWindow: { _ in windowPresented.fulfill() }
        )
        defer { authorization.cancel() }

        XCTAssertTrue(authorization.start { _ in })
        await fulfillment(of: [windowPresented], timeout: 1)
        XCTAssertTrue(authorization.isActive)
    }

    func testClientIDOverrideDoesNotReplaceDefaultConfiguration() throws {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "base-client-id",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )
        var webView: TwitchOAuthTestWebView?
        let authorization = TwitchOAuthAuthorization(
            configuration: configuration,
            makeWebView: { webConfiguration in
                let view = TwitchOAuthTestWebView(frame: .zero, configuration: webConfiguration)
                webView = view
                return view
            },
            presentWindow: { _ in }
        )
        defer { authorization.cancel() }

        XCTAssertTrue(authorization.start(clientID: "override-client-id") { _ in })
        XCTAssertEqual(try clientID(from: XCTUnwrap(webView?.lastRequest?.url)), "override-client-id")
        authorization.cancel()

        XCTAssertTrue(authorization.start { _ in })
        XCTAssertEqual(try clientID(from: XCTUnwrap(webView?.lastRequest?.url)), "base-client-id")
        authorization.cancel()
    }

    func testAuthorizationInterceptsCallbackInRealWebKit() async throws {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "client-id",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"],
            authorizationTimeout: 5
        )
        let completed = expectation(description: "OAuth authorization completed")
        var webView: TwitchOAuthTestWebView?
        var result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        let authorization = TwitchOAuthAuthorization(
            configuration: configuration,
            makeWebView: { webConfiguration in
                let view = TwitchOAuthTestWebView(frame: .zero, configuration: webConfiguration)
                webView = view
                return view
            },
            presentWindow: { _ in }
        )
        defer { authorization.cancel() }

        XCTAssertTrue(
            authorization.start { authorizationResult in
                result = authorizationResult
                completed.fulfill()
            }
        )
        let authorizationURL = try XCTUnwrap(webView?.lastRequest?.url)
        let state = try authorizationState(from: authorizationURL)
        let redirectURI = try redirectURI(from: authorizationURL)
        let fragment = "#access_token=webkit-token&scope=user%3Aread%3Afollows&state=\(state)"
            + "&token_type=bearer"
        let callbackURL = try XCTUnwrap(URL(string: redirectURI + fragment))
        webView?.stopLoading()
        _ = webView?.load(URLRequest(url: callbackURL))

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(result, .success("webkit-token"))
    }

    func testAuthorizationTimesOutWithoutCallback() async {
        let configuration = TwitchOAuthAuthorization.Configuration(
            clientID: "client-id",
            serverPort: 65432,
            requiredScopes: ["user:read:follows"],
            authorizationTimeout: 0.05
        )
        let completed = expectation(description: "OAuth authorization timed out")
        var result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?
        let authorization = TwitchOAuthAuthorization(
            configuration: configuration,
            presentWindow: { _ in }
        )
        defer { authorization.cancel() }

        XCTAssertTrue(
            authorization.start { authorizationResult in
                result = authorizationResult
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(result, .failure(.timedOut))
    }

    func testCallbackRejectsMissingRequiredScope() {
        let result = TwitchOAuthAuthorization.parseCallback(
            queryItems: [
                URLQueryItem(name: "token_type", value: "bearer"),
                URLQueryItem(name: "access_token", value: "test-token"),
                URLQueryItem(name: "scope", value: "chat:read"),
                URLQueryItem(name: "state", value: "expected")
            ],
            expectedState: "expected",
            requiredScopes: ["user:read:follows"]
        )

        XCTAssertEqual(result, .failure(.missingRequiredScope(["user:read:follows"])))
    }

    private func clientID(from authorizationURL: URL) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "client_id" })?.value
        )
    }

    private func authorizationState(from authorizationURL: URL) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "state" })?.value
        )
    }

    private func redirectURI(from authorizationURL: URL) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
        )
    }
}

final class TwitchOAuthTestWebView: WKWebView {
    private(set) var lastRequest: URLRequest?

    override func load(_ request: URLRequest) -> WKNavigation? {
        lastRequest = request
        return super.load(request)
    }
}
