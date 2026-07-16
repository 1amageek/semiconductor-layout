import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    func updateLayerClusters(
        layer: LayoutLayerID,
        editedKeys: Set<FlatShapeKey>,
        dirtyRects: [LayoutRect]
    ) throws {
        guard let rules = tech.ruleSet(for: layer),
              shapeKeysByLayer[layer]?.isEmpty == false else {
            clusterStateByLayer[layer] = nil
            return
        }
        let halo = service.clusterHalo(for: rules, tech: tech)
        // Take ownership out of the dictionary: a subscript read would
        // leave a second reference and turn every in-place mutation below
        // into a full copy of the per-cluster dictionaries — at ~83k
        // single-shape clusters that copy IS the apply cost.
        var state = clusterStateByLayer.removeValue(forKey: layer) ?? LayerClusterState()
        if state.clusters.isEmpty {
            let layerPairs = currentLayerPairs(layer: layer)
            state = LayerClusterState()
            try installClusters(
                try service.shapeClusters(
                    of: layerPairs.map(\.shape), keys: layerPairs.map(\.key), halo: halo, tech: tech
                ),
                analyzedPairs: layerPairs,
                into: &state
            )
            rebuildClusterGrid(in: &state)
            clusterStateByLayer[layer] = state
            return
        }

        // Affected clusters: those owning an edited occurrence plus those
        // whose halo reach touches edited geometry.
        var affected: Set<FlatShapeKey> = []
        for key in editedKeys {
            if let clusterKey = state.clusterOfShape[key] { affected.insert(clusterKey) }
        }
        for rect in dirtyRects {
            for clusterKey in clusterKeys(near: rect, margin: halo, state: state)
            where !affected.contains(clusterKey) {
                affected.insert(clusterKey)
            }
        }

        // Re-partition the affected membership plus the edited shapes, then
        // pull in any untouched cluster a fresh cluster now reaches; repeat
        // until the boundary is closed. The fixed point restores the global
        // partition restricted to the subset. The subset is materialized
        // from the shape table in flatten order; edited keys whose shape
        // was removed by this delta — or moved to ANOTHER layer, leaving
        // the same key pointing at a foreign-layer shape — resolve to
        // nothing here, exactly like the layer-array filter they replace.
        var subsetKeys = editedKeys
        for clusterKey in affected {
            guard let cluster = state.clusters[clusterKey] else { continue }
            subsetKeys.formUnion(cluster.memberKeys)
        }
        var analyzedPairs: [(key: FlatShapeKey, shape: LayoutShape)] = []
        var newClusters: [LayerShapeCluster] = []
        while true {
            analyzedPairs = subsetKeys
                .sorted { shapeOrder($0) < shapeOrder($1) }
                .compactMap { key in
                    guard let shape = shapeByKey[key], shape.layer == layer else { return nil }
                    return (key: key, shape: shape)
                }
            newClusters = analyzedPairs.isEmpty ? [] : try service.shapeClusters(
                of: analyzedPairs.map(\.shape),
                keys: analyzedPairs.map(\.key),
                halo: halo,
                tech: tech
            )
            var grew = false
            for cluster in newClusters {
                for oldKey in clusterKeys(near: cluster.boundingBox, margin: halo, state: state)
                where !affected.contains(oldKey) {
                    guard let old = state.clusters[oldKey] else { continue }
                    affected.insert(oldKey)
                    subsetKeys.formUnion(old.memberKeys)
                    grew = true
                }
            }
            if !grew { break }
        }

        for clusterKey in affected {
            guard let old = state.clusters.removeValue(forKey: clusterKey) else { continue }
            state.clusterGrid?.remove(key: clusterKey)
            for member in old.memberKeys { state.clusterOfShape[member] = nil }
            state.widthAreaByCluster[clusterKey] = nil
            state.spacingByCluster[clusterKey] = nil
        }
        try installClusters(newClusters, analyzedPairs: analyzedPairs, into: &state)
        clusterStateByLayer[layer] = state
    }

    func installClusters(
        _ clusters: [LayerShapeCluster],
        analyzedPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        into state: inout LayerClusterState
    ) throws {
        for cluster in clusters {
            state.clusters[cluster.key] = cluster
            state.clusterGrid?.insert(key: cluster.key, box: cluster.boundingBox)
            for member in cluster.memberKeys { state.clusterOfShape[member] = cluster.key }
            let clusterShapes = cluster.memberIndices.map { analyzedPairs[$0].shape }
            let widthArea = try service.checkWidthAndArea(shapes: clusterShapes, tech: tech)
            if !widthArea.isEmpty { state.widthAreaByCluster[cluster.key] = widthArea }
            let spacing = try service.checkSpacing(shapes: clusterShapes, tech: tech)
            if !spacing.isEmpty { state.spacingByCluster[cluster.key] = spacing }
        }
    }

    func rebuildClusterGrid(in state: inout LayerClusterState) {
        let boxes = state.clusters.values.map { (key: $0.key, box: $0.boundingBox) }
        state.clusterGrid = MutableFlatShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes.map(\.box))
        )
    }

    func clusterKeys(
        near rect: LayoutRect,
        margin: Double,
        state: LayerClusterState
    ) -> [FlatShapeKey] {
        if state.clusters.count >= 512, let grid = state.clusterGrid {
            return grid.neighbours(of: rect, margin: margin)
        }
        return state.clusters.compactMap { key, cluster in
            cluster.boundingBox.expanded(by: margin, margin).intersects(rect) ? key : nil
        }.sorted()
    }
}
