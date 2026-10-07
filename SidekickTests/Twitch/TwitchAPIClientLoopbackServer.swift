import Foundation
import Network

// NWListener is thread-safe; callbacks use a private serial queue and state lock.
// Response is immutable; the test owns listener lifetime.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TwitchAPIClientTests.LoopbackHTTPServer")
    private let stateLock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let responseBody: Data
    private var localPort: UInt16?
    private var failure: NWError?

    var baseURL: URL? {
        guard let localPort = stateLock.withLock({ localPort }) else { return nil }
        return URL(string: "http://127.0.0.1:\(localPort)")
    }

    init(responseBody: Data) throws {
        self.responseBody = responseBody
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateLock.withLock { self.localPort = self.listener.port?.rawValue }
                self.ready.signal()
            case let .failed(error):
                self.stateLock.withLock { self.failure = error }
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw URLError(.timedOut)
        }
        if let failure = stateLock.withLock({ failure }) {
            listener.cancel()
            throw failure
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = buffer
            if let data { request.append(data) }
            guard request.count <= 16_384 else {
                connection.cancel()
                return
            }
            if request.range(of: Data([13, 10, 13, 10])) != nil {
                self.sendResponse(on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: request)
            }
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let headerFields = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(responseBody.count)",
            "Connection: close",
            "",
            ""
        ]
        var response = Data(headerFields.joined(separator: "\r\n").utf8)
        response.append(responseBody)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
