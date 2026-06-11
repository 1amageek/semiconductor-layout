import Foundation
import LayoutCore
import LayoutTech

/// One conductor element of the flattened design as the connectivity
/// engine sees it: the geometry that participates in contact tests plus
/// the metadata needed to derive verdicts.
///
/// Vias are represented by their cut rectangle (the conducting plug); the
/// layer is `nil` for vias because their contact rule is "touches a shape
/// on the via definition's top or bottom layer", evaluated through
/// `LayoutDRCService.shouldConnect`.
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
    var boundingBox: LayoutRect
}
