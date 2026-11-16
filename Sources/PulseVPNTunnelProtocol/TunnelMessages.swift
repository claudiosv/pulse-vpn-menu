import Foundation

/// What the app sends the provider through
/// `NETunnelProviderSession.sendProviderMessage` (as JSON).
public struct TunnelRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        /// Report the session status and any log lines after `afterLog`.
        case poll
        /// Drop and re-establish the link (~ SIGUSR2), then report as `poll`.
        case reconnect
    }

    public var operation: Operation
    /// The last log sequence number the app already has; 0 for everything
    /// the provider still holds.
    public var afterLog: Int

    public init(_ operation: Operation, afterLog: Int = 0) {
        self.operation = operation
        self.afterLog = afterLog
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> TunnelRequest? {
        try? JSONDecoder().decode(TunnelRequest.self, from: data)
    }
}

/// The provider's answer to every `TunnelRequest`.
public struct TunnelReply: Codable, Sendable, Equatable {
    /// `TunnelConstants.protocolVersion` as built into the extension. The
    /// app refuses to work with one that reports a different version.
    public var protocolVersion: Int
    public var status: SessionStatus
    /// Timestamped session log lines newer than the request's `afterLog`.
    public var logLines: [String]
    /// Sequence number of the last line in `logLines` (or the request's
    /// `afterLog` if there were none); pass it as the next `afterLog`.
    public var lastLogSequence: Int

    public init(
        protocolVersion: Int = TunnelConstants.protocolVersion,
        status: SessionStatus, logLines: [String] = [], lastLogSequence: Int = 0
    ) {
        self.protocolVersion = protocolVersion
        self.status = status
        self.logLines = logLines
        self.lastLogSequence = lastLogSequence
    }

    public func encoded() -> Data? { try? JSONEncoder.tunnel.encode(self) }

    public static func decode(_ data: Data) -> TunnelReply? {
        try? JSONDecoder.tunnel.decode(TunnelReply.self, from: data)
    }
}

extension JSONEncoder {
    static let tunnel: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    static let tunnel: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
