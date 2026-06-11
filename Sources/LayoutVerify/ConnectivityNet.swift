import Foundation
import LayoutCore

/// One electrically connected conductor piece of the flattened design,
/// found purely from geometry: shapes touching on the same layer and vias
/// touching shapes on their top/bottom layers, with no reliance on
/// declared net labels.
///
/// `declaredNetIDs` lists which document nets claim geometry inside this
/// piece — two or more means the piece physically shorts those nets, zero
/// means floating metal.
public struct ConnectivityNet: Equatable, Sendable {
    /// IDs of the shapes belonging to this conductor piece, unique and
    /// sorted for deterministic comparison.
    public var shapeIDs: [UUID]
    /// IDs of the vias belonging to this conductor piece, unique and
    /// sorted for deterministic comparison.
    public var viaIDs: [UUID]
    /// Document nets with at least one declared element inside this
    /// piece, sorted for deterministic comparison.
    public var declaredNetIDs: [UUID]
    /// Union of the member bounding boxes.
    public var boundingBox: LayoutRect

    /// Canonical member identities (sorted); the live session and the
    /// batch extractor must agree on these exactly.
    var memberKeys: [ConnectivityElementKey]
}
