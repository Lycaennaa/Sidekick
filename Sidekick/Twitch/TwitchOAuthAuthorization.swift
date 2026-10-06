import AppKit
import Foundation
import WebKit

@MainActor
final class TwitchOAuthAuthorization: NSObject, NSWindowDelegate, WKNavigationDelegate {
    struct Configuration: Equatable, Sendable {
        static let appDefault = Configuration(
            clientID: TwitchOAuthConfiguration.effectiveClientID,
            serverPort: 65432,
            requiredScopes: ["user:read:follows"]
        )

        let clientID: String
        let serverPort: UInt16
        let requiredScopes: [String]
        let authorizationTimeout: TimeInterval

        var redirectURI: String {
            redirectURI(for: serverPort)
        }

        init(
            clientID: String,
            serverPort: UInt16,
            requiredScopes: [String],
            authorizationTimeout: TimeInterval = 120
        ) {
            self.clientID = clientID
            self.serverPort = serverPort
            self.requiredScopes = requiredScopes
            self.authorizationTimeout = authorizationTimeout
        }

        func replacingClientID(_ clientID: String) -> Self {
            Self(
                clientID: clientID,
                serverPort: serverPort,
                requiredScopes: requiredScopes,
                authorizationTimeout: authorizationTimeout
            )
        }

        func redirectURI(for port: UInt16) -> String {
            "http://localhost:\(port)/redirect"
        }
    }
    enum AuthorizationError: Error, Equatable, LocalizedError, Sendable {
        case alreadyInProgress
        case invalidConfiguration
        case fallbackUnavailable
        case cancelled
        case timedOut
        case accessDenied
        case invalidCallback
        case missingRequiredScope([String])

        var errorDescription: String? {
            switch self {
            case .alreadyInProgress:
                "Twitch sign-in is already in progress."
            case .invalidConfiguration:
                "Twitch sign-in is not configured correctly."
            case .fallbackUnavailable:
                "Browser fallback for Twitch sign-in is unavailable."
            case .cancelled:
                "Twitch sign-in was cancelled."
            case .timedOut:
                "Twitch sign-in timed out."
            case .accessDenied:
                "Twitch sign-in was denied or cancelled."
            case .invalidCallback:
                "Twitch returned an invalid OAuth response."
            case let .missingRequiredScope(scopes):
                "Twitch token did not include the \(scopes.joined(separator: ", ")) scope."
            }
        }
    }

    typealias WebViewFactory = @MainActor (WKWebViewConfiguration) -> WKWebView
    typealias WindowPresenter = @MainActor (NSWindowController) -> Void

    private static let maximumTimerInterval = TimeInterval(UInt64.max) / 1_000_000_000

    private let configuration: Configuration
    private let makeWebView: WebViewFactory
    private let presentWindow: WindowPresenter
    private var webView: WKWebView?
    private var windowController: NSWindowController?
    private var expectedState: String?
    private var completion: ((Result<String, AuthorizationError>) -> Void)?
    private var authorizationTimeoutTask: Task<Void, Never>?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?

    init(
        configuration: Configuration = .appDefault,
        makeWebView: @escaping WebViewFactory = { configuration in
            WKWebView(frame: .zero, configuration: configuration)
        },
        presentWindow: @escaping WindowPresenter = { controller in
            controller.showWindow(nil)
            controller.window?.center()
            controller.window?.makeKeyAndOrderFront(nil)
        }
    ) {
        self.configuration = configuration
        self.makeWebView = makeWebView
        self.presentWindow = presentWindow
        super.init()
    }

    var isActive: Bool {
        completion != nil
    }

    @discardableResult
    func start(
        clientID: String? = nil,
        completion: @escaping (Result<String, AuthorizationError>) -> Void
    ) -> Bool {
        guard !isActive else {
            completion(.failure(.alreadyInProgress))
            return false
        }
        let attemptConfiguration = configuration.replacingClientID(clientID ?? configuration.clientID)
        guard Self.isValid(attemptConfiguration) else {
            completion(.failure(.invalidConfiguration))
            return false
        }

        nextOperationID &+= 1
        let operationID = nextOperationID
        let state = UUID().uuidString
        expectedState = state
        activeOperationID = operationID
        self.completion = completion

        let webView = makeWebView(WKWebViewConfiguration())
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Twitch"
        window.contentView = webView
        window.delegate = self
        self.webView = webView
        windowController = NSWindowController(window: window)
        if let windowController {
            presentWindow(windowController)
        }
        guard let authorizationURL = Self.authorizationURL(
            configuration: attemptConfiguration,
            state: state
        ) else {
            finish(.failure(.invalidConfiguration), operationID: operationID)
            return false
        }
        webView.load(URLRequest(url: authorizationURL))

        let timeout = attemptConfiguration.authorizationTimeout
        authorizationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: TwitchOAuthAuthorization.nanoseconds(for: timeout))
            } catch {
                return
            }
            guard let self, self.isCurrent(operationID) else { return }
            self.finish(.failure(.timedOut), operationID: operationID)
        }
        return true
    }

    func cancel() {
        guard isActive else { return }
        finish(.failure(.cancelled))
    }

    static func authorizationURL(
        configuration: Configuration,
        state: String
    ) -> URL? {
        guard isValid(configuration), !state.isEmpty else { return nil }
        var components = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.requiredScopes.joined(separator: " ")),
            URLQueryItem(name: "force_verify", value: "true"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    static func parseCallback(
        queryItems: [URLQueryItem],
        expectedState: String,
        requiredScopes: [String]
    ) -> Result<String, AuthorizationError> {
        var values: [String: String] = [:]
        for item in queryItems where values[item.name] == nil {
            values[item.name] = item.value
        }
        guard values["state"] == expectedState else {
            return .failure(.invalidCallback)
        }
        if values["error"] != nil {
            return .failure(.accessDenied)
        }
        guard values["token_type"]?.lowercased() == "bearer",
              let rawToken = values["access_token"],
              !TwitchOAuthToken.normalized(rawToken).isEmpty else {
            return .failure(.invalidCallback)
        }

        let grantedScopes = Set(
            (values["scope"] ?? "")
                .split { $0 == " " || $0 == "+" }
                .map(String.init)
        )
        guard requiredScopes.allSatisfy(grantedScopes.contains) else {
            return .failure(.missingRequiredScope(requiredScopes))
        }
        return .success(TwitchOAuthToken.normalized(rawToken))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, isCallbackURL(url) else {
            decisionHandler(.allow)
            return
        }
        guard webView === self.webView,
              navigationAction.targetFrame?.isMainFrame == true,
              let operationID = activeOperationID else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
        complete(url, operationID: operationID)
    }

    func windowWillClose(_ notification: Notification) {
        guard isActive else { return }
        finish(.failure(.cancelled))
    }

    private func isCallbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
            && url.host?.lowercased() == "localhost"
            && url.port == Int(configuration.serverPort)
            && url.path == "/redirect"
    }

    private func complete(_ url: URL, operationID: UInt64) {
        guard isCurrent(operationID), let expectedState else { return }
        guard let queryItems = Self.callbackQueryItems(from: url),
              queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            return
        }
        finish(
            Self.parseCallback(
                queryItems: queryItems,
                expectedState: expectedState,
                requiredScopes: configuration.requiredScopes
            ),
            operationID: operationID
        )
    }

    private static func callbackQueryItems(from url: URL) -> [URLQueryItem]? {
        guard let fragment = url.fragment, !fragment.isEmpty,
              let components = URLComponents(string: "http://localhost?\(fragment)") else {
            return nil
        }
        return components.queryItems
    }

    private static func isValid(_ configuration: Configuration) -> Bool {
        TwitchOAuthConfiguration.isConfigured(configuration.clientID)
            && configuration.serverPort > 0
            && !configuration.requiredScopes.isEmpty
            && configuration.authorizationTimeout.isFinite
            && configuration.authorizationTimeout > 0
            && configuration.authorizationTimeout < maximumTimerInterval
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval < maximumTimerInterval else { return UInt64.max }
        return UInt64(interval * 1_000_000_000)
    }

    private func isCurrent(_ operationID: UInt64) -> Bool {
        activeOperationID == operationID && completion != nil
    }

    private func finish(
        _ result: Result<String, AuthorizationError>,
        operationID: UInt64? = nil
    ) {
        guard let completion,
              let activeOperationID,
              operationID == nil || operationID == activeOperationID else { return }
        self.completion = nil
        self.activeOperationID = nil
        expectedState = nil
        authorizationTimeoutTask?.cancel()
        authorizationTimeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        windowController?.window?.delegate = nil
        windowController?.close()
        windowController = nil
        webView = nil
        completion(result)
    }
}
