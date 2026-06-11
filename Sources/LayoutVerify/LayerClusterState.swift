import Foundation
import LayoutCore

/// Per-layer incremental state for the width/area and spacing checks:
/// the halo-closed cluster partition plus the violations each cluster
/// produced when it was last checked.
struct LayerClusterState {
    /// True when non-Manhattan geometry forced the whole layer into a
    /// single cluster. Tracked so a later edit that restores Manhattan
    /// geometry rebuilds the real partition.
    var isMonolithic = false

    /// Clusters by their stable key.
    var clusters: [FlatShapeKey: LayerShapeCluster] = [:]

    /// Cluster key of every member occurrence, for O(1) edit-to-cluster
    /// lookup.
    var clusterOfShape: [FlatShapeKey: FlatShapeKey] = [:]

    /// Width/area violations per cluster; clusters with none hold no entry.
    var widthAreaByCluster: [FlatShapeKey: [LayoutViolation]] = [:]

    /// Spacing violations per cluster; clusters with none hold no entry.
    var spacingByCluster: [FlatShapeKey: [LayoutViolation]] = [:]
}
