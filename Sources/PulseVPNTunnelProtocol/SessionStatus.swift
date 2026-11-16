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

/// Everything the app needs to know about the provider's VPN session, in one
/// value, carried in every `TunnelReply`. Adding a field doesn't touch the
/// message format.
public struct SessionStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// No session in this provider yet.
        case none
        case running
        case exited
    }

    public var state: State
    /// libopenconnect's result once `exited`: -EINTR after a requested stop,
    /// -EPERM for a rejected cookie, -EPIPE when the server ended it, ...
    /// or `TunnelConstants.needsLoginExitCode`.
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
        try? JSONDecoder.tunnel.decode(SessionStatus.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder.tunnel.encode(self)
    }
}
