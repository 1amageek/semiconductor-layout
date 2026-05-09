import Foundation
import LayoutCore
import LayoutTech

/// Resolves routing congestion by iteratively ripping up and rerouting nets.
struct RipUpRerouter: Sendable {

    struct Configuration: Sendable {
        var maxIterations: Int = 20
        var maxRipUpsPerNet: Int = 3
    }

    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Resolves overcongestion by ripping up and rerouting affected nets.
    ///
    /// - Parameters:
    ///   - routedNets: Current routing results (modified in place).
    ///   - netInfos: Net metadata including Steiner trees.
    ///   - segments: Segments per net ID (modified in place).
    ///   - congestion: Congestion grid (modified in place).
    ///   - obstMap: Obstruction map for collision detection (modified in place).
    ///   - shapeIDMap: Mapping from net ID to obstruction shape IDs (modified in place).
    ///   - tech: Technology database.
    ///   - grid: Layout grid spacing.
    /// - Returns: Names of nets still unrouted after resolution.
    func resolve(
        routedNets: inout [RoutedNet],
        netInfos: [(id: UUID, name: String, tree: SteinerTree)],
        segments: inout [UUID: [ChannelRouter.RouteSegment]],
        congestion: inout CongestionGrid,
        obstMap: inout ObstructionMap,
        shapeIDMap: inout [UUID: [UUID]],
        tech: LayoutTechDatabase,
        grid: Double
    ) -> [String] {
        let channelRouter = ChannelRouter()
        var ripUpCounts: [UUID: Int] = [:]
        var unrouted: [String] = []

        for _ in 0..<configuration.maxIterations {
            guard congestion.hasOvercongestion() else { break }

            // Update history costs -- cells that remain overcongested accumulate penalty
            congestion.updateHistoryCosts(factor: 1.0)

            let overcongestedCells = congestion.overcongestedCells()
            guard !overcongestedCells.isEmpty else { break }

            // Find nets passing through overcongested cells
            var candidateNets: [(id: UUID, name: String, tree: SteinerTree, congestionScore: Double)] = []
            for info in netInfos {
                guard (ripUpCounts[info.id] ?? 0) < configuration.maxRipUpsPerNet else { continue }
                guard let netSegments = segments[info.id] else { continue }

                var score = 0.0
                for seg in netSegments {
                    score += congestion.congestionCostWithHistory(
                        from: seg.from,
                        to: seg.to,
                        isHorizontal: seg.isHorizontal
                    )
                }
                if score > 0 {
                    candidateNets.append((id: info.id, name: info.name, tree: info.tree, congestionScore: score))
                }
            }

            // Sort by congestion contribution (descending) -- rip up most congested first
            candidateNets.sort { $0.congestionScore > $1.congestionScore }

            guard let victim = candidateNets.first else { break }

            // Rip up: remove demand from congestion grid
            if let victimSegments = segments[victim.id] {
                for seg in victimSegments {
                    congestion.removeDemand(
                        from: seg.from,
                        to: seg.to,
                        isHorizontal: seg.isHorizontal
                    )
                }
            }

            // Rip up: remove victim net's shapes from obstruction map
            if let victimShapeIDs = shapeIDMap[victim.id] {
                obstMap.remove(shapeIDs: victimShapeIDs)
                shapeIDMap[victim.id] = nil
            }

            // Reroute with congestion-aware cost using the shared obstruction map
            let newResult = channelRouter.routeCongestionAware(
                tree: victim.tree,
                tech: tech,
                congestion: &congestion,
                obstMap: obstMap,
                grid: grid
            )

            // Register new shapes with obstruction map and update shapeIDMap
            var newShapeIDs: [UUID] = []
            let newShapes = newResult.segments.map { segmentToShape($0, grid: grid) }
            for shape in newShapes {
                let shapeID = obstMap.register(shape: shape)
                newShapeIDs.append(shapeID)
            }
            shapeIDMap[victim.id] = newShapeIDs

            // Update routing result
            segments[victim.id] = newResult.segments
            if let routeIdx = routedNets.firstIndex(where: { $0.netID == victim.id }) {
                let viaDef = tech.vias.first
                var vias: [LayoutVia] = []
                if let viaDef {
                    for pos in newResult.viaPositions {
                        vias.append(LayoutVia(
                            viaDefinitionID: viaDef.id,
                            position: pos
                        ))
                    }
                }
                routedNets[routeIdx] = RoutedNet(
                    netID: victim.id, shapes: newShapes, vias: vias
                )
            }

            ripUpCounts[victim.id, default: 0] += 1
        }

        // Identify still-overcongested nets
        if congestion.hasOvercongestion() {
            for info in netInfos {
                guard let netSegments = segments[info.id] else { continue }
                var hasOvercongestion = false
                for seg in netSegments {
                    let cost = congestion.congestionCost(
                        from: seg.from, to: seg.to, isHorizontal: seg.isHorizontal
                    )
                    if cost > 1.0 {
                        hasOvercongestion = true
                        break
                    }
                }
                if hasOvercongestion {
                    unrouted.append(info.name)
                }
            }
        }

        return unrouted
    }

    // MARK: - Helpers

    private func segmentToShape(_ segment: ChannelRouter.RouteSegment, grid: Double) -> LayoutShape {
        let from = segment.from
        let to = segment.to
        let width = segment.width

        if segment.isHorizontal {
            let minX = min(from.x, to.x)
            let maxX = max(from.x, to.x)
            let w = max(maxX - minX, width)
            return LayoutShape(
                layer: segment.layer,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: minX, y: snap(from.y - width / 2, grid: grid)),
                    size: LayoutSize(width: w, height: snap(width, grid: grid))
                ))
            )
        } else {
            let minY = min(from.y, to.y)
            let maxY = max(from.y, to.y)
            let h = max(maxY - minY, width)
            return LayoutShape(
                layer: segment.layer,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: snap(from.x - width / 2, grid: grid), y: minY),
                    size: LayoutSize(width: snap(width, grid: grid), height: h)
                ))
            )
        }
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
