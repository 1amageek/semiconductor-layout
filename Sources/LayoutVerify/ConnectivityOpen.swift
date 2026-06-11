import Foundation
import LayoutCore

/// A declared document net whose geometry sits on two or more mutually
/// disconnected conductor pieces.
public struct ConnectivityOpen: Equatable, Sendable {
    /// The open document net.
    public var netID: UUID
    /// The disconnected conductor pieces carrying this net, in canonical
    /// component order; always at least two.
    public var islands: [ConnectivityIsland]
    /// Minimum spanning tree of suggested connections over `islands`.
    public var flylines: [Flyline]
}
