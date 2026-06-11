import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

// MARK: - Width/Area/Spacing Clustering

/// Partitions a layer's shapes into independent check units for the
/// incremental session.
///
/// Two merged-geometry components interact in the width/area/spacing checks
/// only when geometry of one lies within the layer's largest distance rule
/// of the other, and every reported violation region extends at most
/// `minWidth` (width markers) or the largest spacing rule (gap markers)
/// beyond the component it belongs to. Closing the components under a
/// bounding-box halo of `clusterHalo(for:tech:)` therefore yields groups
/// whose check results — including the bbox-vs-marker contributing-shape
/// payloads — are pairwise independent: running the checks per cluster
/// reproduces the full-layer run bit-exactly.
extension LayoutDRCService {

    /// Interaction halo in microns: the largest distance any width/area/
    /// spacing rule can reach across a gap, plus slack for the micron-to-
    /// database-unit rounding (vertices move at most half a database unit,
    /// and bbox comparisons mix IR-derived and micron-native boxes).
    func clusterHalo(for rules: LayoutLayerRuleSet, tech: LayoutTechDatabase) -> Double {
        let roundingSlack = 2.0 / tech.units.dbuPerMicron
        let ruleReach = max(
            max(rules.minWidth, rules.minSpacing),
            max(rules.minNotch ?? 0, rules.wideSpacing ?? 0)
        )
        return ruleReach + roundingSlack
    }

    /// Whether the shape's database-unit boundary is Manhattan — the same
    /// `PolygonGeometry.isManhattan` predicate the region booleans dispatch
    /// on, so the clustered path is taken exactly when the merged region
    /// stays on the canonical scanline path. Degenerate geometry that
    /// produces no boundary cannot perturb the banding and counts as
    /// Manhattan.
    func isManhattanShape(_ shape: LayoutShape, dbu: Double) -> Bool {
        guard let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu) else {
            return true
        }
        return PolygonGeometry.isManhattan(boundary.points)
    }

    /// Single cluster covering the whole layer: the exact-by-definition
    /// fallback when non-Manhattan geometry makes component banding
    /// unavailable.
    func wholeLayerCluster(
        of shapes: [LayoutShape],
        keys: [FlatShapeKey]
    ) -> LayerShapeCluster {
        let boxes = shapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        var hull = boxes[0]
        for box in boxes.dropFirst() {
            hull = hull.union(box)
        }
        return LayerShapeCluster(
            key: keys.min()!,
            memberKeys: keys,
            memberIndices: Array(shapes.indices),
            boundingBox: hull
        )
    }

    /// Halo-closed clusters of the shapes (one layer, Manhattan geometry).
    /// `keys[i]` is the stable occurrence identity of `shapes[i]`.
    ///
    /// Nodes are the connected components of the boolean-merged region plus
    /// one pseudo node per shape that produces no containable geometry;
    /// nodes whose bounding boxes come within `halo` of each other share a
    /// cluster. Shapes follow the component containing the first vertex of
    /// their database-unit boundary. A shape that fails the containment
    /// lookup degrades safely to a pseudo node: its bbox sits inside its
    /// component's bbox (up to rounding covered by the halo slack), so it
    /// still lands in the same cluster and membership is unchanged.
    func shapeClusters(
        of shapes: [LayoutShape],
        keys: [FlatShapeKey],
        halo: Double,
        tech: LayoutTechDatabase
    ) -> [LayerShapeCluster] {
        guard !shapes.isEmpty else { return [] }
        let dbu = tech.units.dbuPerMicron
        let components = mergedRegion(of: shapes, dbu: dbu).connectedComponents()

        var componentBoxes: [LayoutRect] = []
        componentBoxes.reserveCapacity(components.count)
        for component in components {
            guard let bb = component.boundingBox else {
                // Components of a non-empty region always carry geometry; an
                // empty one would only over-merge clusters near the origin,
                // which is conservative, never wrong.
                assertionFailure("connected component without geometry")
                componentBoxes.append(.zero)
                continue
            }
            componentBoxes.append(irBoundingBoxToRect(bb, dbu: dbu))
        }

        // Assign each shape to the component containing its first boundary
        // vertex. The grid prunes candidates; containment is evaluated in
        // database units, where the vertex lies exactly on the original
        // polygon and the merged region is boundary-inclusive.
        var componentOfShape: [Int?] = Array(repeating: nil, count: shapes.count)
        if !components.isEmpty {
            let assignmentGrid = ShapeGridIndex(
                boundingBoxes: componentBoxes,
                cellSize: ShapeGridIndex.defaultCellSize(for: componentBoxes)
            )
            let margin = 1.0 / dbu
            for (shapeIndex, shape) in shapes.enumerated() {
                guard let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu),
                      let vertex = boundary.points.first else { continue }
                let probe = LayoutRect(
                    origin: LayoutPoint(x: Double(vertex.x) / dbu, y: Double(vertex.y) / dbu),
                    size: .zero
                )
                for candidate in assignmentGrid.candidateIndices(near: probe, margin: margin)
                where components[candidate].contains(vertex) {
                    componentOfShape[shapeIndex] = candidate
                    break
                }
            }
        }

        // Node table: components first, then pseudo nodes for unassigned
        // shapes. Pseudo nodes contribute no violations but must co-cluster
        // with neighbours they could appear under as bbox contributors.
        var nodeBoxes = componentBoxes
        var nodeOfShape: [Int] = Array(repeating: 0, count: shapes.count)
        for (shapeIndex, shape) in shapes.enumerated() {
            if let component = componentOfShape[shapeIndex] {
                nodeOfShape[shapeIndex] = component
            } else {
                nodeOfShape[shapeIndex] = nodeBoxes.count
                nodeBoxes.append(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
            }
        }

        // Union nodes whose bounding boxes come within the halo.
        var parent = Array(nodeBoxes.indices)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            var current = node
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        let nodeGrid = ShapeGridIndex(
            boundingBoxes: nodeBoxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: nodeBoxes)
        )
        for i in nodeBoxes.indices {
            let reach = nodeBoxes[i].expanded(by: halo, halo)
            for j in nodeGrid.candidateIndices(near: nodeBoxes[i], margin: halo)
            where j > i && reach.intersects(nodeBoxes[j]) {
                let rootI = find(i)
                let rootJ = find(j)
                if rootI != rootJ { parent[rootJ] = rootI }
            }
        }

        // Group shapes by root; document order within each cluster. Every
        // component's geometry comes from some shape whose bbox lies within
        // the halo of that component, so every root is reachable from a
        // shape and no geometry is dropped.
        var memberIndicesByRoot: [Int: [Int]] = [:]
        var rootOrder: [Int] = []
        for shapeIndex in shapes.indices {
            let root = find(nodeOfShape[shapeIndex])
            if memberIndicesByRoot[root] == nil { rootOrder.append(root) }
            memberIndicesByRoot[root, default: []].append(shapeIndex)
        }
        var hullByRoot: [Int: LayoutRect] = [:]
        for node in nodeBoxes.indices {
            let root = find(node)
            hullByRoot[root] = hullByRoot[root].map { $0.union(nodeBoxes[node]) } ?? nodeBoxes[node]
        }

        return rootOrder.map { root in
            let memberIndices = memberIndicesByRoot[root]!
            let memberKeys = memberIndices.map { keys[$0] }
            return LayerShapeCluster(
                key: memberKeys.min()!,
                memberKeys: memberKeys,
                memberIndices: memberIndices,
                boundingBox: hullByRoot[root]!
            )
        }
    }
}
