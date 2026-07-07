import Foundation
import LayoutCore
import LayoutTech

/// Steiner-tree-based routing engine with congestion-aware rip-up/reroute.
///
/// Improvement over SimpleRoutingEngine:
/// - Uses Hanan grid RSMT for multi-pin nets (vs Manhattan MST)
/// - Congestion-aware L-shape bend selection
/// - Iterative rip-up and reroute for congestion resolution
/// - Same power rail routing strategy as SimpleRoutingEngine
public struct SteinerRoutingEngine: RoutingEngine {

    public struct Configuration: Sendable {
        public var enableRipUpReroute: Bool
        public var maxRerouteIterations: Int

        public init(
            enableRipUpReroute: Bool = true,
            maxRerouteIterations: Int = 20
        ) {
            self.enableRipUpReroute = enableRipUpReroute
            self.maxRerouteIterations = maxRerouteIterations
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func route(
        nets: [RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase
    ) throws -> RoutingResult {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Width = try tech.requiredRuleSet(for: m1ID).minWidth
        let m2Width = try tech.requiredRuleSet(for: m2ID).minWidth
        let grid = tech.grid

        guard let viaDef = tech.vias.first else {
            return RoutingResultContracts.resultWithoutViaDefinition(for: nets)
        }

        // 1. Initialize obstruction map
        var obstMap = ObstructionMap()
        for obs in obstructions {
            obstMap.register(shape: obs)
        }
        registerPinObstructions(nets: nets, obstacleMap: &obstMap)

        // 2. Compute bounding box for congestion grid
        let bbox = computeBoundingBox(
            placements: placements, cells: cells, obstructions: obstructions
        )
        var congestion = try CongestionGrid(boundingBox: bbox, tech: tech)

        // 3. Identify power rails
        let railYPositions = obstructions.compactMap { shape -> Double? in
            guard shape.layer == m1ID else { return nil }
            switch shape.geometry {
            case .rect(let r): return r.origin.y + r.size.height / 2
            default: return nil
            }
        }.sorted()
        let vssRailY = railYPositions.first
        let vddRailY = railYPositions.last

        // 4. Separate power and signal nets
        var routes: [RoutedNet] = []
        var signalNets: [RoutingNet] = []
        var unroutedNets: [String] = []

        for net in nets {
            if net.isPower {
                guard !net.pins.isEmpty else {
                    unroutedNets.append(net.name)
                    continue
                }
                let targetY = powerRailTarget(
                    netName: net.name, vddRailY: vddRailY, vssRailY: vssRailY
                )
                if let railY = targetY {
                    let result = routePowerNet(
                        net: net, railY: railY,
                        m1ID: m1ID, m2ID: m2ID,
                        m1Width: m1Width, m2Width: m2Width,
                        viaDef: viaDef, grid: grid, obstMap: &obstMap,
                        congestion: &congestion
                    )
                    routes.append(result)
                } else {
                    unroutedNets.append(net.name)
                }
            } else if net.pins.count >= 2 {
                signalNets.append(net)
            } else if net.pins.count == 1 {
                routes.append(RoutedNet(netID: net.id))
            } else {
                // Zero-pin net: nothing to route
                unroutedNets.append(net.name)
            }
        }

        // 5. Build Steiner trees and route signal nets
        let channelRouter = ChannelRouter()
        var trees: [UUID: SteinerTree] = [:]
        var segmentMap: [UUID: [ChannelRouter.RouteSegment]] = [:]
        var shapeIDMap: [UUID: [UUID]] = [:]  // netID -> obstMap shape IDs

        // Sort signal nets: fewer pins first (easier nets first)
        let sortedSignals = signalNets.sorted { $0.pins.count < $1.pins.count }

        for net in sortedSignals {
            let pins = net.pins.map(\.absolutePosition)
            let tree = SteinerTree.construct(pins: pins)
            trees[net.id] = tree

            let result: ChannelRouter.RouteResult
            do {
                result = try channelRouter.routeCongestionAware(
                    tree: tree,
                    tech: tech,
                    congestion: &congestion,
                    obstMap: obstMap,
                    grid: grid,
                    netID: net.id
                )
            } catch ChannelRouter.RoutingFailure.unroutableEdge {
                unroutedNets.append(net.name)
                continue
            }

            segmentMap[net.id] = result.segments

            // Convert to RoutedNet and track shape IDs in obstMap
            let routedNet = convertToRoutedNet(
                segments: result.segments,
                viaPositions: result.viaPositions,
                netID: net.id,
                viaDef: viaDef,
                grid: grid,
                obstMap: &obstMap,
                shapeIDMap: &shapeIDMap
            )
            routes.append(routedNet)
        }

        // 6. Rip-up and reroute if enabled
        if configuration.enableRipUpReroute && congestion.hasOvercongestion() {
            let netInfos = sortedSignals.compactMap { net -> (id: UUID, name: String, tree: SteinerTree)? in
                guard let tree = trees[net.id] else { return nil }
                return (id: net.id, name: net.name, tree: tree)
            }

            let rerouter = RipUpRerouter(configuration: .init(
                maxIterations: configuration.maxRerouteIterations
            ))
            let stillUnrouted = try rerouter.resolve(
                routedNets: &routes,
                netInfos: netInfos,
                segments: &segmentMap,
                congestion: &congestion,
                obstMap: &obstMap,
                shapeIDMap: &shapeIDMap,
                tech: tech,
                grid: grid
            )
            unroutedNets.append(contentsOf: stillUnrouted)
        }

        return RoutingResult(routes: routes, unroutedNets: unroutedNets)
    }

    // MARK: - Power Net Routing

    private func powerRailTarget(
        netName: String, vddRailY: Double?, vssRailY: Double?
    ) -> Double? {
        let name = netName.lowercased()
        if name == "vdd" || name == "vcc" { return vddRailY }
        if name == "vss" || name == "gnd" || name == "0" { return vssRailY }
        return vssRailY ?? vddRailY
    }

    private func registerPinObstructions(
        nets: [RoutingNet],
        obstacleMap: inout ObstructionMap
    ) {
        for net in nets {
            for pin in net.pins {
                obstacleMap.register(shape: LayoutShape(
                    layer: pin.layer,
                    netID: net.id,
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(
                            x: pin.absolutePosition.x - pin.size.width / 2,
                            y: pin.absolutePosition.y - pin.size.height / 2
                        ),
                        size: pin.size
                    ))
                ))
            }
        }
    }

    private func routePowerNet(
        net: RoutingNet, railY: Double,
        m1ID: LayoutLayerID, m2ID: LayoutLayerID,
        m1Width: Double, m2Width: Double,
        viaDef: LayoutViaDefinition, grid: Double,
        obstMap: inout ObstructionMap,
        congestion: inout CongestionGrid
    ) -> RoutedNet {
        var routedNet = RoutedNet(netID: net.id)
        for pin in net.pins {
            let pinPos = pin.absolutePosition
            if abs(pinPos.y - railY) < grid {
                routedNet.vias.append(LayoutVia(
                    viaDefinitionID: viaDef.id,
                    position: snap2D(pinPos, grid: grid)
                ))
                continue
            }

            routedNet.vias.append(LayoutVia(
                viaDefinitionID: viaDef.id,
                position: snap2D(pinPos, grid: grid)
            ))

            let railPoint = LayoutPoint(x: pinPos.x, y: railY)
            let vShape = makeVertical(
                from: pinPos, to: railPoint, layer: m2ID, width: m2Width, grid: grid
            )
            obstMap.register(shape: vShape)
            routedNet.shapes.append(vShape)
            congestion.addDemand(from: snap2D(pinPos, grid: grid), to: snap2D(railPoint, grid: grid), isHorizontal: false)

            routedNet.vias.append(LayoutVia(
                viaDefinitionID: viaDef.id,
                position: snap2D(railPoint, grid: grid)
            ))
        }
        return routedNet
    }

    // MARK: - Conversion Helpers

    private func convertToRoutedNet(
        segments: [ChannelRouter.RouteSegment],
        viaPositions: [LayoutPoint],
        netID: UUID,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap,
        shapeIDMap: inout [UUID: [UUID]]
    ) -> RoutedNet {
        var shapes: [LayoutShape] = []
        var registeredIDs: [UUID] = []
        for seg in segments {
            var shape = segmentToShape(seg, grid: grid)
            shape.netID = netID
            let shapeID = obstMap.register(shape: shape)
            registeredIDs.append(shapeID)
            shapes.append(shape)
        }
        shapeIDMap[netID] = registeredIDs

        let vias = viaPositions.map {
            LayoutVia(viaDefinitionID: viaDef.id, position: $0)
        }

        return RoutedNet(netID: netID, shapes: shapes, vias: vias)
    }

    private func segmentToShape(
        _ segment: ChannelRouter.RouteSegment, grid: Double
    ) -> LayoutShape {
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

    private func makeVertical(
        from: LayoutPoint, to: LayoutPoint,
        layer: LayoutLayerID, width: Double, grid: Double
    ) -> LayoutShape {
        let minY = min(from.y, to.y)
        let maxY = max(from.y, to.y)
        let h = max(snap(maxY - minY, grid: grid), snap(width, grid: grid))
        return LayoutShape(
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(
                    x: snap(from.x - width / 2, grid: grid),
                    y: snap(minY, grid: grid)
                ),
                size: LayoutSize(width: snap(width, grid: grid), height: h)
            ))
        )
    }

    private func makeViaLandingShape(
        at point: LayoutPoint,
        layer: LayoutLayerID,
        size: Double,
        grid: Double,
        netID: UUID?
    ) -> LayoutShape {
        let snappedSize = ContactArrayHelper.snapUp(size + 2 * grid, grid: grid)
        return LayoutShape(
            layer: layer,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(
                    x: snap(point.x - snappedSize / 2, grid: grid),
                    y: snap(point.y - snappedSize / 2, grid: grid)
                ),
                size: LayoutSize(width: snappedSize, height: snappedSize)
            ))
        )
    }

    // MARK: - Geometry

    private func computeBoundingBox(
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape]
    ) -> LayoutRect {
        var bbox: LayoutRect?
        for (_, transform) in placements {
            let pt = transform.translation
            let r = LayoutRect(origin: pt, size: LayoutSize(width: 0.01, height: 0.01))
            bbox = bbox.map { $0.union(r) } ?? r
        }
        for obs in obstructions {
            let r = LayoutGeometryAnalysis.boundingBox(for: obs.geometry)
            bbox = bbox.map { $0.union(r) } ?? r
        }
        return bbox?.expanded(by: 1.0, 1.0) ?? LayoutRect(
            origin: .zero,
            size: LayoutSize(width: 10, height: 10)
        )
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }

    private func snap2D(_ point: LayoutPoint, grid: Double) -> LayoutPoint {
        LayoutPoint(x: snap(point.x, grid: grid), y: snap(point.y, grid: grid))
    }
}
