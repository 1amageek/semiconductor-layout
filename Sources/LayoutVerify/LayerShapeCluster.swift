import Foundation
import LayoutCore

/// One independent width/area/spacing check unit on a layer: a halo-closed
/// group of merged-geometry components plus the degenerate shapes near them.
///
/// Two components belong to the same cluster when their bounding boxes come
/// within the layer's interaction halo of each other, so every violating
/// edge pair and every contributing shape of a violation lies inside one
/// cluster. Running the width/area and spacing checks per cluster therefore
/// reproduces the full-layer violation multiset bit-exactly.
struct LayerShapeCluster {
    /// Stable identity: the smallest member key. A pure function of the
    /// membership, so the same group of shape occurrences maps to the same
    /// key whether it was built by a full rebuild or an incremental update.
    let key: FlatShapeKey

    /// Member shape occurrence keys in document order.
    let memberKeys: [FlatShapeKey]

    /// Indices of the members into the shape array the cluster was built
    /// from. Only valid against that array; used to slice the member shapes
    /// for the per-cluster check run.
    let memberIndices: [Int]

    /// Hull of the member node bounding boxes (components and degenerate
    /// shapes), in microns. Conservative: used with the halo to find the
    /// clusters an edit can influence.
    let boundingBox: LayoutRect
}
