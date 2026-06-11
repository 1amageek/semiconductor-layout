import Foundation
import LayoutCore

/// A suggested connection between two islands of an open net: the
/// shortest straight segment between the nearest member rectangles of the
/// two conductor pieces.
///
/// The set of flylines for one open net forms a minimum spanning tree
/// over its islands, so following every flyline closes the net with no
/// redundant edges.
public struct Flyline: Equatable, Sendable {
    /// The open document net this flyline belongs to.
    public var netID: UUID
    /// Index into the open's `islands` of the piece the segment starts on.
    public var fromIslandIndex: Int
    /// Index into the open's `islands` of the piece the segment ends on.
    public var toIslandIndex: Int
    /// Point on the `fromIslandIndex` piece nearest to the other piece.
    public var start: LayoutPoint
    /// Point on the `toIslandIndex` piece nearest to the other piece.
    public var end: LayoutPoint
    /// Euclidean gap between the two pieces; zero when they touch only
    /// across layers (stacked without a via).
    public var length: Double
}
