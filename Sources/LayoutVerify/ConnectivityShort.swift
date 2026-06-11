import Foundation
import LayoutCore

/// A conductor piece that physically connects geometry declared on two or
/// more different document nets.
///
/// Because the verdict comes from the extracted component, it catches
/// shorts the pairwise same-layer overlap check cannot see: bridges
/// through unlabeled geometry and connections mediated by vias.
public struct ConnectivityShort: Equatable, Sendable {
    /// The shorted document nets, sorted, always at least two.
    public var netIDs: [UUID]
    /// IDs of the shapes forming the shorting conductor piece, unique and
    /// sorted.
    public var shapeIDs: [UUID]
    /// IDs of the vias forming the shorting conductor piece, unique and
    /// sorted.
    public var viaIDs: [UUID]
    /// Bounding box of the shorting conductor piece.
    public var region: LayoutRect

    /// Canonical member identities of the shorting component (sorted).
    var memberKeys: [ConnectivityElementKey]
}
