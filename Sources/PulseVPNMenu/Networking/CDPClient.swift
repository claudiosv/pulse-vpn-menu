import Foundation

/// A minimal Chrome DevTools Protocol JSON-RPC client over
/// `URLSessionWebSocketTask` (built into Foundation — no external
/// dependency). Direct translation of the wire behavior confirmed in the
/// vendored nodriver source's `Connection.send()`/`_listener()`
/// (`nodriver/core/connection.py`): an incrementing integer `id`, a map of
/// pending continuations keyed by that id, and a background receive loop
/// that resolves a pending continuation when a message carries a matching
/// `id`, or otherwise treats it as an unsolicited event (ignored here — the
/// DSID flow only needs request/response, not event subscriptions).
/// Wraps a CDP response's `result` dictionary so it can cross actor
/// isolation boundaries: `[String: Any]` itself is not `Sendable`, but this
/// is only ever produced by decoding a JSON message on `CDPClient`'s own
/// actor and then handed, unmodified, to exactly one caller awaiting it —
/// the `@unchecked` conformance reflects that single-owner handoff, not an
/// actual absence of thread-safety concerns.
struct CDPResult: @unchecked Sendable {
    let dictionary: [String: Any]
}

actor CDPClient {
    enum CDPError: Error, CustomStringConvertible {
        case notConnected
        case protocolError(message: String)
        case connectionClosed
        case invalidResponse

        var description: String {
            switch self {
            case .notConnected: return "Not connected to Chrome DevTools."
            case .protocolError(let message): return "CDP error: \(message)"
            case .connectionClosed: return "Chrome DevTools connection closed."
            case .invalidResponse: return "Received an unparseable CDP response."
            }
        }
    }

    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<CDPResult, Error>] = [:]
    private var receiveTask: Task<Void, Never>?

    func connect(to url: URL) {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func close() {
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAllPending(with: CDPError.connectionClosed)
    }

    @discardableResult
    func send(method: String, params: [String: Any] = [:], sessionId: String? = nil) async throws -> CDPResult {
        guard let task else { throw CDPError.notConnected }

        let id = nextID
        nextID += 1

        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId {
            message["sessionId"] = sessionId
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { await self?.fail(id: id, error: error) }
            }
        }
    }

    private func fail(id: Int, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func failAllPending(with error: Error) {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    private func receiveLoop() async {
        while true {
            guard let task else { return }
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleIncoming(text)
                case .data(let data):
                    handleIncoming(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                failAllPending(with: error)
                return
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        // Unsolicited CDP events have "method" but no "id" — nothing in the
        // DSID flow needs to observe those, so they're simply ignored.
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else {
            return
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            continuation.resume(throwing: CDPError.protocolError(message: message))
            return
        }
        continuation.resume(returning: CDPResult(dictionary: (object["result"] as? [String: Any]) ?? [:]))
    }
}
