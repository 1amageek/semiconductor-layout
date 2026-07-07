import Foundation
import LayoutCore
import LayoutTech

/// Parallel-array view of an ordered element table, in the layout the
/// shared `LayoutDRCService.shouldConnect` predicate consumes.
struct ConnectivityParallelArrays {
    var geometries: [LayoutGeometry]
    var layers: [LayoutLayerID?]
    var isVia: [Bool]
    var viaDefs: [LayoutViaDefinition?]
    var viaCutRects: [[LayoutRect]]
    var viaContactRectsByLayer: [[LayoutLayerID: [LayoutRect]]]
}
