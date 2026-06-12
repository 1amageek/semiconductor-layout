import Foundation
import LayoutCore

/// One disconnected conductor piece of an open net.
///
/// An island is the whole electrically connected component the net's
/// declared geometry sits on — including any unlabeled geometry fused to
/// it — because closing the open means joining these conductor pieces,
/// whichever of their member rectangles the connection lands on.
public struct ConnectivityIsland: Equatable, Sendable {
    /// IDs of the shapes in this conductor piece, unique and sorted.
    public var shapeIDs: [UUID]
    /// IDs of the vias in this conductor piece, unique and sorted.
    public var viaIDs: [UUID]
    /// Union of the member bounding boxes.
    public var boundingBox: LayoutRect
    /// Occurrence-exact member geometry (layer + box), in canonical
    /// member order. Unlike `shapeIDs`, instance reuse does not alias.
    public var memberFootprints: [ConnectivityIslandFootprint]

    /// Canonical member identities (sorted); flyline endpoints iterate
    /// these in order so live and batch emit bit-identical geometry.
    var memberKeys: [ConnectivityElementKey]
}
