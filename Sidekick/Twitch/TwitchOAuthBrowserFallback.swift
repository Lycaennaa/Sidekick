import AppKit
import Foundation
import Network

@MainActor
final class TwitchOAuthBrowserFallback {
    private enum Request {
        case redirect
        case token([URLQueryItem])
        case invalid
        case methodNotAllowed
        case notFound
    }

    private enum RequestReadiness {
        case incomplete
        case complete
        case invalid
    }

    private struct Response {
        let status: Int
        let body: String
        let result: Result<String, TwitchOAuthAuthorization.AuthorizationError>?

        init(
            status: Int,
            body: String,
            result: Result<String, TwitchOAuthAuthorization.AuthorizationError>? = nil
        ) {
            self.status = status
            self.body = body
            self.result = result
        }
    }

    private static let maximumRequestBytes = 64 * 1024
    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let maximumTimerInterval = TimeInterval(UInt64.max) / 1_000_000_000

    private let configuration: TwitchOAuthAuthorization.Configuration
    private var activeConfiguration: TwitchOAuthAuthorization.Configuration?
    private let openBrowser: (URL) -> Bool
    private var listener: NWListener?
    private var connection: NWConnection?
    private var requestData = Data()
    private var expectedState: String?
    private var completion: ((Result<String, TwitchOAuthAuthorization.AuthorizationError>) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?

    init(
        configuration: TwitchOAuthAuthorization.Configuration = .appDefault,
        openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        self.openBrowser = openBrowser
    }

    var isActive: Bool {
        completion != nil
    }

    @discardableResult
    func start(
        clientID: String? = nil,
        completion: @escaping (Result<String, TwitchOAuthAuthorization.AuthorizationError>) -> Void
    ) -> Bool {
        guard !isActive else {
            completion(.failure(.alreadyInProgress))
            return false
        }
        let attemptConfiguration = configuration.replacingClientID(clientID ?? configuration.clientID)
        guard Self.isValid(attemptConfiguration),
              let port = NWEndpoint.Port(rawValue: attemptConfiguration.serverPort) else {
            completion(.failure(.invalidConfiguration))
            return false
        }
        activeConfiguration = attemptConfiguration

        nextOperationID &+= 1
        let operationID = nextOperationID
        let state = UUID().uuidString
        expectedState = state
        activeOperationID = operationID
        self.completion = completion
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        do {
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state, operationID: operationID)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, operationID: operationID)
                }
            }
            listener.start(queue: .main)
        } catch {
            finish(.failure(.fallbackUnavailable), operationID: operationID)
            return false
        }

        let timeout = attemptConfiguration.authorizationTimeout
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
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

    private func handleListenerState(_ state: NWListener.State, operationID: UInt64) {
        guard isCurrent(operationID) else { return }
        switch state {
        case .ready:
            guard let activeConfiguration else {
                finish(.failure(.invalidConfiguration), operationID: operationID)
                return
            }
            guard let authorizationURL = TwitchOAuthAuthorization.authorizationURL(
                configuration: activeConfiguration,
                state: expectedState ?? ""
            ) else {
                finish(.failure(.invalidConfiguration), operationID: operationID)
                return
            }
            if !openBrowser(authorizationURL) {
                finish(.failure(.fallbackUnavailable), operationID: operationID)
            }
        case .failed:
            finish(.failure(.fallbackUnavailable), operationID: operationID)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, operationID: UInt64) {
        guard isCurrent(operationID), self.connection == nil else {
            connection.cancel()
            return
        }
        self.connection = connection
        requestData.removeAll(keepingCapacity: true)
        connection.start(queue: .main)
        receiveRequest(on: connection, operationID: operationID)
    }

    private func receiveRequest(on connection: NWConnection, operationID: UInt64) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumRequestBytes
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(operationID), self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.requestData.append(data)
                }
                if self.requestData.count > Self.maximumRequestBytes {
                    self.sendResponse(status: 413, body: "Request too large.", operationID: operationID)
                    return
                }
                switch self.requestReadiness() {
                case .invalid:
                    self.sendResponse(status: 400, body: "Invalid request.", operationID: operationID)
                case .incomplete where error == nil && !isComplete:
                    self.receiveRequest(on: connection, operationID: operationID)
                default:
                    self.handleRequest(on: connection, operationID: operationID)
                }
            }
        }
    }

    private func handleRequest(on connection: NWConnection, operationID: UInt64) {
        let response: Response
        switch request() {
        case .redirect:
            response = Response(status: 200, body: TwitchOAuthFallbackPage.html)
        case let .token(queryItems):
            response = tokenResponse(queryItems, operationID: operationID)
        case .methodNotAllowed:
            response = Response(status: 405, body: "Method not allowed.")
        case .invalid:
            response = Response(status: 400, body: "Invalid request.")
        case .notFound:
            response = Response(status: 404, body: "Not found.")
        }
        sendResponse(
            status: response.status,
            body: response.body,
            operationID: operationID,
            finishingWith: response.result
        )
    }

    private func request() -> Request {
        guard let headerRange = requestData.range(of: Self.headerDelimiter),
              let header = String(data: requestData[..<headerRange.lowerBound], encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first,
              let contentLength = contentLength(in: header) else {
            return .invalid
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .invalid }
        let target = String(parts[1])
        guard target.hasPrefix("/"),
              let components = URLComponents(string: "http://localhost\(target)") else {
            return .invalid
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard requestData.count == bodyEnd else { return .invalid }
        let body = requestData[bodyStart..<bodyEnd]
        switch components.path {
        case "/redirect":
            return parts[0] == "GET" ? .redirect : .methodNotAllowed
        case "/token":
            guard parts[0] == "POST",
                  let bodyString = String(data: body, encoding: .utf8),
                  let bodyComponents = URLComponents(string: "http://localhost?\(bodyString)") else {
                return .methodNotAllowed
            }
            return .token(bodyComponents.queryItems ?? [])
        default:
            return .notFound
        }
    }

    private func requestReadiness() -> RequestReadiness {
        guard let headerRange = requestData.range(of: Self.headerDelimiter) else {
            return .incomplete
        }
        guard let header = String(data: requestData[..<headerRange.lowerBound], encoding: .utf8),
              let contentLength = contentLength(in: header) else {
            return .invalid
        }
        let availableBodyLength = requestData.count - headerRange.upperBound
        if availableBodyLength < contentLength { return .incomplete }
        return availableBodyLength == contentLength ? .complete : .invalid
    }

    private func contentLength(in header: String) -> Int? {
        var contentLength: Int?
        for line in header.components(separatedBy: "\r\n") {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            guard fields[0].lowercased() == "content-length" else { continue }
            guard contentLength == nil,
                  let length = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  length >= 0,
                  length <= Self.maximumRequestBytes else {
                return nil
            }
            contentLength = length
        }
        return contentLength ?? 0
    }

    private func tokenResponse(
        _ queryItems: [URLQueryItem],
        operationID: UInt64
    ) -> Response {
        guard isCurrent(operationID), let expectedState else {
            return Response(status: 400, body: "Sign-in expired.")
        }
        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            return Response(status: 400, body: "Invalid callback.")
        }
        let result = TwitchOAuthAuthorization.parseCallback(
            queryItems: queryItems,
            expectedState: expectedState,
            requiredScopes: configuration.requiredScopes
        )
        switch result {
        case .success:
            return Response(
                status: 200,
                body: "Authentication successful. You may close this window.",
                result: result
            )
        case let .failure(error):
            return Response(status: 400, body: error.localizedDescription, result: .failure(error))
        }
    }

    private func sendResponse(
        status: Int,
        body: String,
        operationID: UInt64,
        finishingWith result: Result<String, TwitchOAuthAuthorization.AuthorizationError>? = nil
    ) {
        guard isCurrent(operationID), let connection else { return }
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var responseData = Data(response.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(operationID) else { return }
                self.clearConnection()
                if let result {
                    self.finish(result, operationID: operationID)
                }
            }
        })
    }

    private func clearConnection() {
        connection?.cancel()
        connection = nil
        requestData.removeAll(keepingCapacity: true)
    }

    private func isCurrent(_ operationID: UInt64) -> Bool {
        activeOperationID == operationID && completion != nil
    }

    private func finish(
        _ result: Result<String, TwitchOAuthAuthorization.AuthorizationError>,
        operationID: UInt64? = nil
    ) {
        guard let completion,
              let activeOperationID,
              operationID == nil || operationID == activeOperationID else { return }
        self.completion = nil
        self.activeOperationID = nil
        expectedState = nil
        activeConfiguration = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        clearConnection()
        listener?.cancel()
        listener = nil
        completion(result)
    }

    private static func isValid(_ configuration: TwitchOAuthAuthorization.Configuration) -> Bool {
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

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}
