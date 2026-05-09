import Foundation
import LayoutCore
import LayoutTech

/// Routes Steiner tree segments onto physical metal tracks.
///
/// Assigns horizontal segments to M1 and vertical segments to M2,
/// inserting VIAs at layer transition points within each edge independently.
struct ChannelRouter: Sendable {

    struct RouteSegment: Sendable {
        var layer: LayoutLayerID
        var from: LayoutPoint
        var to: LayoutPoint
        var width: Double
        var isHorizontal: Bool
    }

    struct RouteResult: Sendable {
        var segments: [RouteSegment]
        var viaPositions: [LayoutPoint]
    }

    /// Routes a Steiner tree into physical segments with VIA insertions.
    ///
    /// Each tree edge is processed independently (not assuming sequential connectivity).
    /// VIAs are inserted at layer transition points within each L-shaped decomposition.
    func route(
        tree: SteinerTree,
        tech: LayoutTechDatabase,
        congestion: inout CongestionGrid,
        obstMap: ObstructionMap,
        grid: Double
    ) -> RouteResult {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Width = tech.ruleSet(for: m1ID)?.minWidth ?? 0.23
        let m2Width = tech.ruleSet(for: m2ID)?.minWidth ?? 0.28

        var segments: [RouteSegment] = []
        var viaPositions: [LayoutPoint] = []

        // Build adjacency for pin-endpoint detection
        let pinIndices = Set(tree.points.indices.filter { tree.points[$0].isOriginalPin })

        for edge in tree.edges {
            let p1 = tree.points[edge.from].position
            let p2 = tree.points[edge.to].position
            let dx = abs(p1.x - p2.x)
            let dy = abs(p1.y - p2.y)
            let p1IsPin = pinIndices.contains(edge.from)
            let p2IsPin = pinIndices.contains(edge.to)

            if dx < 1e-9 {
                // Pure vertical (M2)
                let seg = RouteSegment(
                    layer: m2ID, from: snap2D(p1, grid: grid), to: snap2D(p2, grid: grid),
                    width: m2Width, isHorizontal: false
                )
                segments.append(seg)
                congestion.addDemand(from: seg.from, to: seg.to, isHorizontal: false)
                // VIA at pin endpoints (pins are on M1, segment is M2)
                if p1IsPin { viaPositions.append(snap2D(p1, grid: grid)) }
                if p2IsPin { viaPositions.append(snap2D(p2, grid: grid)) }
            } else if dy < 1e-9 {
                // Pure horizontal (M1) — no VIA needed at pin endpoints
                let seg = RouteSegment(
                    layer: m1ID, from: snap2D(p1, grid: grid), to: snap2D(p2, grid: grid),
                    width: m1Width, isHorizontal: true
                )
                segments.append(seg)
                congestion.addDemand(from: seg.from, to: seg.to, isHorizontal: true)
            } else {
                // L-shape: horizontal first (M1→M2), bend point gets VIA
                let bend = LayoutPoint(x: p2.x, y: p1.y)
                let seg1 = RouteSegment(
                    layer: m1ID,
                    from: snap2D(p1, grid: grid),
                    to: snap2D(bend, grid: grid),
                    width: m1Width,
                    isHorizontal: true
                )
                let seg2 = RouteSegment(
                    layer: m2ID,
                    from: snap2D(bend, grid: grid),
                    to: snap2D(p2, grid: grid),
                    width: m2Width,
                    isHorizontal: false
                )
                segments.append(seg1)
                segments.append(seg2)
                congestion.addDemand(from: seg1.from, to: seg1.to, isHorizontal: true)
                congestion.addDemand(from: seg2.from, to: seg2.to, isHorizontal: false)
                // VIA at bend (layer transition M1→M2)
                viaPositions.append(snap2D(bend, grid: grid))
                // VIA at p2 if it is a pin (M1 pin, M2 segment end)
                if p2IsPin { viaPositions.append(snap2D(p2, grid: grid)) }
            }
        }

        return RouteResult(segments: segments, viaPositions: deduplicateVias(viaPositions))
    }

    /// Routes with congestion-aware cost, preferring less congested paths.
    ///
    /// For L-shaped segments, tries both bend directions and picks the
    /// one with lower congestion. If both L-shape options collide with
    /// obstructions, falls back to MazeRouter for A* pathfinding.
    /// VIAs are only inserted at actual layer transition points relevant
    /// to pin connections.
    func routeCongestionAware(
        tree: SteinerTree,
        tech: LayoutTechDatabase,
        congestion: inout CongestionGrid,
        obstMap: ObstructionMap,
        grid: Double
    ) -> RouteResult {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Width = tech.ruleSet(for: m1ID)?.minWidth ?? 0.23
        let m2Width = tech.ruleSet(for: m2ID)?.minWidth ?? 0.28
        let m1Spacing = tech.ruleSet(for: m1ID)?.minSpacing ?? 0.23
        let m2Spacing = tech.ruleSet(for: m2ID)?.minSpacing ?? 0.28

        var segments: [RouteSegment] = []
        var viaPositions: [LayoutPoint] = []

        let pinIndices = Set(tree.points.indices.filter { tree.points[$0].isOriginalPin })
        let mazeRouter = MazeRouter()

        for edge in tree.edges {
            let p1 = tree.points[edge.from].position
            let p2 = tree.points[edge.to].position
            let dx = abs(p1.x - p2.x)
            let dy = abs(p1.y - p2.y)
            let p1IsPin = pinIndices.contains(edge.from)
            let p2IsPin = pinIndices.contains(edge.to)

            if dx < 1e-9 {
                // Pure vertical (M2)
                let seg = RouteSegment(
                    layer: m2ID, from: snap2D(p1, grid: grid), to: snap2D(p2, grid: grid),
                    width: m2Width, isHorizontal: false
                )
                segments.append(seg)
                congestion.addDemand(from: seg.from, to: seg.to, isHorizontal: false)
                // VIA only at pin endpoints
                if p1IsPin { viaPositions.append(snap2D(p1, grid: grid)) }
                if p2IsPin { viaPositions.append(snap2D(p2, grid: grid)) }
            } else if dy < 1e-9 {
                // Pure horizontal (M1)
                let seg = RouteSegment(
                    layer: m1ID, from: snap2D(p1, grid: grid), to: snap2D(p2, grid: grid),
                    width: m1Width, isHorizontal: true
                )
                segments.append(seg)
                congestion.addDemand(from: seg.from, to: seg.to, isHorizontal: true)
            } else {
                // L-shape: try both bend directions
                let bendA = LayoutPoint(x: p2.x, y: p1.y)
                let bendB = LayoutPoint(x: p1.x, y: p2.y)

                // Check obstruction for option A (H first, then V)
                let rectA1 = segmentBoundingRect(
                    from: snap2D(p1, grid: grid), to: snap2D(bendA, grid: grid),
                    width: m1Width, isHorizontal: true
                )
                let rectA2 = segmentBoundingRect(
                    from: snap2D(bendA, grid: grid), to: snap2D(p2, grid: grid),
                    width: m2Width, isHorizontal: false
                )
                let collisionA = obstMap.hasCollision(rect: rectA1, layer: m1ID, spacing: m1Spacing)
                    || obstMap.hasCollision(rect: rectA2, layer: m2ID, spacing: m2Spacing)

                // Check obstruction for option B (V first, then H)
                let rectB1 = segmentBoundingRect(
                    from: snap2D(p1, grid: grid), to: snap2D(bendB, grid: grid),
                    width: m2Width, isHorizontal: false
                )
                let rectB2 = segmentBoundingRect(
                    from: snap2D(bendB, grid: grid), to: snap2D(p2, grid: grid),
                    width: m1Width, isHorizontal: true
                )
                let collisionB = obstMap.hasCollision(rect: rectB1, layer: m2ID, spacing: m2Spacing)
                    || obstMap.hasCollision(rect: rectB2, layer: m1ID, spacing: m1Spacing)

                // If both L-shapes collide, fall back to MazeRouter
                if collisionA && collisionB {
                    if let mazeSegments = mazeRouter.route(
                        from: snap2D(p1, grid: grid),
                        to: snap2D(p2, grid: grid),
                        layers: (m1: m1ID, m2: m2ID),
                        congestion: congestion,
                        obstMap: obstMap,
                        tech: tech
                    ) {
                        for seg in mazeSegments {
                            segments.append(seg)
                            congestion.addDemand(from: seg.from, to: seg.to, isHorizontal: seg.isHorizontal)
                        }
                        // Add vias at layer transitions in maze path
                        for i in 1..<mazeSegments.count {
                            let prev = mazeSegments[i - 1]
                            let curr = mazeSegments[i]
                            if prev.layer != curr.layer {
                                viaPositions.append(curr.from)
                            }
                        }
                        if p1IsPin { viaPositions.append(snap2D(p1, grid: grid)) }
                        if p2IsPin { viaPositions.append(snap2D(p2, grid: grid)) }
                        continue
                    }
                    // MazeRouter failed: fall through to best L-shape anyway
                }

                let costA = congestion.congestionCostWithHistory(from: p1, to: bendA, isHorizontal: true)
                    + congestion.congestionCostWithHistory(from: bendA, to: p2, isHorizontal: false)
                let costB = congestion.congestionCostWithHistory(from: p1, to: bendB, isHorizontal: false)
                    + congestion.congestionCostWithHistory(from: bendB, to: p2, isHorizontal: true)

                // Prefer non-colliding option; among non-colliding, prefer lower cost
                let useA: Bool
                if collisionA && !collisionB {
                    useA = false
                } else if collisionB && !collisionA {
                    useA = true
                } else {
                    useA = costA <= costB
                }

                let bend = useA ? bendA : bendB
                let firstIsH = useA

                let seg1 = RouteSegment(
                    layer: firstIsH ? m1ID : m2ID,
                    from: snap2D(p1, grid: grid),
                    to: snap2D(bend, grid: grid),
                    width: firstIsH ? m1Width : m2Width,
                    isHorizontal: firstIsH
                )
                let seg2 = RouteSegment(
                    layer: firstIsH ? m2ID : m1ID,
                    from: snap2D(bend, grid: grid),
                    to: snap2D(p2, grid: grid),
                    width: firstIsH ? m2Width : m1Width,
                    isHorizontal: !firstIsH
                )

                segments.append(seg1)
                segments.append(seg2)
                congestion.addDemand(from: seg1.from, to: seg1.to, isHorizontal: firstIsH)
                congestion.addDemand(from: seg2.from, to: seg2.to, isHorizontal: !firstIsH)

                // VIA at bend point (always a layer transition)
                viaPositions.append(snap2D(bend, grid: grid))
                // VIA at pin endpoints connected via M2
                if !firstIsH && p1IsPin { viaPositions.append(snap2D(p1, grid: grid)) }
                if firstIsH && p2IsPin { viaPositions.append(snap2D(p2, grid: grid)) }
            }
        }

        return RouteResult(segments: segments, viaPositions: deduplicateVias(viaPositions))
    }

    // MARK: - Segment Bounding Rect

    /// Computes the bounding rectangle for a route segment.
    private func segmentBoundingRect(
        from: LayoutPoint, to: LayoutPoint, width: Double, isHorizontal: Bool
    ) -> LayoutRect {
        if isHorizontal {
            let minX = min(from.x, to.x)
            let maxX = max(from.x, to.x)
            let w = max(maxX - minX, width)
            return LayoutRect(
                origin: LayoutPoint(x: minX, y: from.y - width / 2),
                size: LayoutSize(width: w, height: width)
            )
        } else {
            let minY = min(from.y, to.y)
            let maxY = max(from.y, to.y)
            let h = max(maxY - minY, width)
            return LayoutRect(
                origin: LayoutPoint(x: from.x - width / 2, y: minY),
                size: LayoutSize(width: width, height: h)
            )
        }
    }

    // MARK: - Helpers

    private func deduplicateVias(_ viaPositions: [LayoutPoint]) -> [LayoutPoint] {
        var uniqueVias: [LayoutPoint] = []
        var viaSet: Set<String> = []
        for via in viaPositions {
            let key = "\(Int64((via.x * 1000).rounded()))_\(Int64((via.y * 1000).rounded()))"
            if !viaSet.contains(key) {
                viaSet.insert(key)
                uniqueVias.append(via)
            }
        }
        return uniqueVias
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }

    private func snap2D(_ point: LayoutPoint, grid: Double) -> LayoutPoint {
        LayoutPoint(x: snap(point.x, grid: grid), y: snap(point.y, grid: grid))
    }
}
