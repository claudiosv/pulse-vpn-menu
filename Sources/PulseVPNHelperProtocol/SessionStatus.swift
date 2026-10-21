import Foundation

/// Why a session ended because the server's certificate was rejected.
public struct CertFailure: Codable, Sendable, Equatable {
    public var reason: String
    /// `pin-sha256:...`; what to store as the profile's pin to trust it.
    public var hash: String?

    public init(reason: String, hash: String?) {
        self.reason = reason
        self.hash = hash
    }
}

/// Everything the app needs to know about the helper's VPN session, in one
/// value. Returned by `sessionStatus` and pushed to observers whenever it
/// changes. It crosses XPC as JSON `Data`: an `NSData` payload sidesteps
/// declaring allowed classes, and adding a field doesn't touch the protocol.
public struct SessionStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// No session since the helper started.
        case none
        case running
        case exited
    }

    public var state: State
    /// libopenconnect's result once `exited`: -EINTR after `stopSession`,
    /// -EPERM for a rejected cookie, -EPIPE when the server ended it, ...
    public var exitCode: Int32
    public var startedAt: Date?
    /// Set when the session ended because the certificate was rejected.
    public var certFailure: CertFailure?
    /// Link state and counters; nil unless running.
    public var snapshot: SessionSnapshot?

    public init(
        state: State, exitCode: Int32 = 0, startedAt: Date? = nil,
        certFailure: CertFailure? = nil, snapshot: SessionSnapshot? = nil
    ) {
        self.state = state
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.certFailure = certFailure
        self.snapshot = snapshot
    }

    public var isRunning: Bool { state == .running }

    public static func decode(_ data: Data) -> SessionStatus? {
        try? JSONDecoder.status.decode(SessionStatus.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder.status.encode(self)
    }
}

extension JSONEncoder {
    fileprivate static let status: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    fileprivate static let status: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Implemented by the app and exported on its XPC connection; the helper
/// calls it to push state changes instead of being polled for them.
/// Counters are not pushed (they change every second): read them with
/// `sessionStatus` at whatever rate the UI wants.
@objc public protocol SessionObserverProtocol {
    /// A JSON-encoded `SessionStatus`, sent whenever the session starts,
    /// ends, or its link state, ESP flag, drop count or tunnel changes.
    func sessionStatusChanged(_ status: Data)
}
