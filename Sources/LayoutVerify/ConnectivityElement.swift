import Foundation
import LayoutCore
import LayoutTech

/// One captured physical band and the metadata needed to derive verdicts.
/// The snapshot/index owns exact contact semantics; geometry and bounds are
/// display/index values. Legacy aggregate preparation remains behind failed
/// public migration gates until its consumers use captured pieces.
struct ConnectivityElement: Sendable {
    var key: ConnectivityElementKey
    /// Original element UUID, for highlighting in the editor. Child
    /// occurrences of a multi-instanced cell share one UUID; the key stays
    /// unique.
    var elementID: UUID
    var isVia: Bool
    /// Declared net membership from the document (nil for unlabeled
    /// geometry, which still conducts).
    var netID: UUID?
    var geometry: LayoutGeometry
    var layer: LayoutLayerID?
    var viaDefinition: LayoutViaDefinition?
    var viaCutRects: [LayoutRect]
    var viaContactRectsByLayer: [LayoutLayerID: [LayoutRect]]
    var boundingBox: LayoutRect
    /// Exact contact authority. Bounds and source UUIDs do not establish contact.
    var conductorCapture: LayoutConductorSnapshot? = nil
    var footprintIndex: Int? = nil
    var declaredNet: LayoutConductorSnapshot.NetReference? = nil
}
