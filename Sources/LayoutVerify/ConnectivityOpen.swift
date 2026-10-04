import Foundation
import LayoutCore

/// A scoped net with disconnected conductor pieces or unconnected pins.
public struct ConnectivityOpen: Equatable, Sendable {
    /// The open document net.
    public var netID: LayoutConductorSnapshot.NetReference
    /// The disconnected conductor pieces carrying this net, in canonical
    /// component order. Unconnected-pin opens can have zero or one island.
    public var islands: [ConnectivityIsland]
    /// Minimum spanning tree of suggested connections over `islands`.
    public var flylines: [Flyline]
    /// Native captured pin indices whose full area has no conductor contact.
    public var unconnectedPinIndices: [Int] = []
}
