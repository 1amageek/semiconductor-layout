import Foundation
import LayoutCore

/// Per-layer incremental state for the width/area and spacing checks:
/// the halo-closed cluster partition plus the violations each cluster
/// produced when it was last checked.
struct LayerClusterState {
    /// Clusters by their stable key.
    var clusters: [FlatShapeKey: LayerShapeCluster] = [:]

    /// Cluster key of every member occurrence, for O(1) edit-to-cluster
    /// lookup.
    var clusterOfShape: [FlatShapeKey: FlatShapeKey] = [:]

    /// Spatial index over cluster bounding boxes for dirty-geometry closure.
    /// Keys are cluster keys, not shape keys.
    var clusterGrid: MutableFlatShapeGridIndex?

    /// Width/area violations per cluster; clusters with none hold no entry.
    var widthAreaByCluster: [FlatShapeKey: [LayoutViolation]] = [:]

    /// Spacing violations per cluster; clusters with none hold no entry.
    var spacingByCluster: [FlatShapeKey: [LayoutViolation]] = [:]
}
