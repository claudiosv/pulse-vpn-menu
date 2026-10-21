import Foundation

/// The helper's view of the running VPN session, JSON-encoded across XPC
/// (an `NSData` reply sidesteps declaring allowed classes for a collection
/// type). Mirrors `OpenConnectSnapshot`; the app never links libopenconnect.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public enum LinkState: String, Codable, Sendable {
        case connecting, up, reconnecting
    }

    public var linkState: LinkState
    public var espEstablished: Bool
    /// Number of times the link dropped and libopenconnect started retrying.
    public var dropCount: Int
    /// Increments each time the counters below are refreshed; 0 until the
    /// first sample.
    public var statsSequence: Int
    public var txPackets: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var rxBytes: UInt64

    public init(
        linkState: LinkState, espEstablished: Bool, dropCount: Int, statsSequence: Int,
        txPackets: UInt64, txBytes: UInt64, rxPackets: UInt64, rxBytes: UInt64
    ) {
        self.linkState = linkState
        self.espEstablished = espEstablished
        self.dropCount = dropCount
        self.statsSequence = statsSequence
        self.txPackets = txPackets
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.rxBytes = rxBytes
    }
}
