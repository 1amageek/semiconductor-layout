import Foundation
import LayoutCore
import LayoutTech

/// L/Z-shape routing engine using Manhattan MST.
///
/// Algorithm:
/// 1. Build minimum spanning tree (MST) per net using Manhattan distance.
/// 2. Route each MST edge:
///    - Same Y: M1 horizontal wire (no VIA needed, pins are on M1).
///    - Same X: M1 short → VIA → M2 vertical → VIA → M1 short.
///    - General: L-shape with collision check, Z-shape fallback.
/// 3. All pins are assumed to be on M1. Layer transitions use VIA1.
public struct SimpleRoutingEngine: RoutingEngine {
    public init() {}

    public func route(
        nets: [RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase
    ) throws -> RoutingResult {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Rules = try tech.requiredRuleSet(for: m1ID)
        let m2Rules = try tech.requiredRuleSet(for: m2ID)

        guard let rawViaDef = tech.vias.first else {
            return RoutingResult(
                routes: [],
                unroutedNets: nets.map(\.name)
            )
        }
        // Landing pads sized from the raw enclosure can fall below the
        // metal min-area/min-width rules; widen the enclosure up front so
        // every via this engine drops is legal on its own.
        let viaDef = ViaLandingRule.sized(rawViaDef, bottomRules: m1Rules, topRules: m2Rules)
        let minM1Width = m1Rules.minWidth
        let minM2Width = m2Rules.minWidth
        let m1Width = max(minM1Width, viaDef.cutSize.width + 2 * viaDef.enclosure.bottom)
        let m2Width = max(minM2Width, viaDef.cutSize.width + 2 * viaDef.enclosure.top)
        let m1Spacing = m1Rules.minSpacing
        let m2Spacing = m2Rules.minSpacing
        let grid = tech.grid

        var obstMap = ObstructionMap()
        for obs in obstructions {
            obstMap.register(shape: obs)
        }
        registerPinObstructions(nets: nets, obstacleMap: &obstMap)

        // Identify power rail Y positions from obstructions.
        // Convention: VSS rail = lowest Y center, VDD rail = highest Y center.
        let railYPositions = obstructions.compactMap { shape -> Double? in
            guard shape.layer == m1ID else { return nil }
            switch shape.geometry {
            case .rect(let r): return r.origin.y + r.size.height / 2
            default: return nil
            }
        }.sorted()
        let vssRailY = railYPositions.first
        let vddRailY = railYPositions.last

        var routes: [RoutedNet] = []
        var unroutedNets: [String] = []

        let orderedNets = nets.sorted { lhs, rhs in
            if lhs.isPower != rhs.isPower {
                return lhs.isPower && !rhs.isPower
            }
            if lhs.isPower {
                return lhs.name < rhs.name
            }
            let lhsScore = routingPriorityScore(lhs)
            let rhsScore = routingPriorityScore(rhs)
            if abs(lhsScore - rhsScore) > 1e-9 {
                return lhsScore < rhsScore
            }
            if lhs.pins.count != rhs.pins.count {
                return lhs.pins.count > rhs.pins.count
            }
            return lhs.name < rhs.name
        }

        let routingBBox = computeRoutingBoundingBox(nets: orderedNets, obstructions: obstructions)
        let congestion = try CongestionGrid(boundingBox: routingBBox, tech: tech)

        for net in orderedNets {
            guard net.pins.count >= 1 else { continue }

            if net.isPower {
                guard net.pins.count >= 2 else {
                    routes.append(RoutedNet(netID: net.id))
                    continue
                }
                // Power net: connect each pin to the nearest power rail via M2 vertical drop.
                let targetRailY = powerRailTarget(
                    netName: net.name, vddRailY: vddRailY, vssRailY: vssRailY
                )
                guard let railY = targetRailY else {
                    unroutedNets.append(net.name)
                    continue
                }
                let result = routePowerNet(
                    net: net, railY: railY,
                    m1ID: m1ID, m2ID: m2ID,
                    m1Width: m1Width, m2Width: m2Width,
                    viaDef: viaDef, grid: grid, obstMap: &obstMap
                )
                routes.append(result)
                continue
            }

            guard net.pins.count >= 2 else {
                if net.pins.count == 1 {
                    routes.append(RoutedNet(netID: net.id))
                }
                continue
            }

            let positions = net.pins.map(\.absolutePosition)
            let edges = manhattanMST(points: positions)

            var routedNet = RoutedNet(netID: net.id)
            var allRouted = true

            for (i, j) in edges {
                let from = positions[i]
                let to = positions[j]

                let result = try routeEdge(
                    netID: net.id,
                    from: from,
                    to: to,
                    m1ID: m1ID,
                    m2ID: m2ID,
                    m1Width: m1Width,
                    m2Width: m2Width,
                    m1Spacing: m1Spacing,
                    m2Spacing: m2Spacing,
                    viaDef: viaDef,
                    grid: grid,
                    tech: tech,
                    congestion: congestion,
                    obstMap: &obstMap
                )

                if let (shapes, vias) = result {
                    routedNet.shapes.append(contentsOf: shapes)
                    routedNet.vias.append(contentsOf: vias)
                } else {
                    allRouted = false
                }
            }

            if !allRouted, let trunkResult = routeExternalM2Trunk(
                net: net,
                routingBounds: routingBBox,
                m1ID: m1ID,
                m2ID: m2ID,
                m2Width: m2Width,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                viaDef: viaDef,
                grid: grid,
                obstMap: &obstMap
            ) {
                routedNet.shapes.append(contentsOf: trunkResult.shapes)
                routedNet.vias.append(contentsOf: trunkResult.vias)
                allRouted = true
            }

            addLayerCrossingVias(
                to: &routedNet,
                netID: net.id,
                m1ID: m1ID,
                m2ID: m2ID,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                viaDef: viaDef,
                grid: grid,
                obstMap: &obstMap
            )

            routes.append(routedNet)
            if !allRouted {
                unroutedNets.append(net.name)
            }
        }

        return RoutingResult(routes: routes, unroutedNets: unroutedNets)
    }

    // MARK: - Power Net Routing

    /// Determines which power rail Y a net should connect to.
    private func powerRailTarget(
        netName: String, vddRailY: Double?, vssRailY: Double?
    ) -> Double? {
        let name = netName.lowercased()
        if name == "vdd" || name == "vcc" {
            return vddRailY
        }
        if name == "vss" || name == "gnd" || name == "0" {
            return vssRailY
        }
        // Unknown power net: pick the nearest rail if available
        return vssRailY ?? vddRailY
    }

    /// Routes a power net by connecting each pin to the power rail via M2 vertical drop.
    private func routePowerNet(
        net: RoutingNet,
        railY: Double,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> RoutedNet {
        var routedNet = RoutedNet(netID: net.id)

        for pin in net.pins {
            let pinPos = pin.absolutePosition
            let railPoint = LayoutPoint(x: pinPos.x, y: railY)

            // If pin is already on the rail, just add a VIA
            if abs(pinPos.y - railY) < grid {
                appendVia(at: pinPos, netID: net.id, viaDef: viaDef, grid: grid, shapes: &routedNet.shapes, vias: &routedNet.vias)
                registerRecentViaLandings(in: routedNet.shapes, obstacleMap: &obstMap)
                continue
            }

            // VIA at pin (M1→M2)
            appendVia(at: pinPos, netID: net.id, viaDef: viaDef, grid: grid, shapes: &routedNet.shapes, vias: &routedNet.vias)
            registerRecentViaLandings(in: routedNet.shapes, obstacleMap: &obstMap)

            // M2 vertical from pin to rail
            let v = makeVertical(
                from: pinPos, to: railPoint, layer: m2ID, width: m2Width, grid: grid, netID: net.id
            )
            obstMap.register(shape: v)
            routedNet.shapes.append(v)

            // VIA at rail (M2→M1)
            appendVia(at: railPoint, netID: net.id, viaDef: viaDef, grid: grid, shapes: &routedNet.shapes, vias: &routedNet.vias)
            registerRecentViaLandings(in: routedNet.shapes, obstacleMap: &obstMap)
        }

        return routedNet
    }

    // MARK: - MST

    /// Prim's algorithm for Manhattan MST.
    private func manhattanMST(points: [LayoutPoint]) -> [(Int, Int)] {
        let n = points.count
        guard n >= 2 else { return [] }

        var inMST = [Bool](repeating: false, count: n)
        var minDist = [Double](repeating: .infinity, count: n)
        var minEdge = [Int](repeating: -1, count: n)
        var edges: [(Int, Int)] = []

        minDist[0] = 0

        for _ in 0..<n {
            var u = -1
            for v in 0..<n {
                if !inMST[v] && (u == -1 || minDist[v] < minDist[u]) {
                    u = v
                }
            }
            guard u != -1 else { break }

            inMST[u] = true
            if minEdge[u] != -1 {
                edges.append((minEdge[u], u))
            }

            for v in 0..<n {
                if !inMST[v] {
                    let d = manhattanDistance(points[u], points[v])
                    if d < minDist[v] {
                        minDist[v] = d
                        minEdge[v] = u
                    }
                }
            }
        }

        return edges
    }

    private func manhattanDistance(_ a: LayoutPoint, _ b: LayoutPoint) -> Double {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    private func routingPriorityScore(_ net: RoutingNet) -> Double {
        guard let first = net.pins.first else { return 0 }
        var minX = first.absolutePosition.x
        var minY = first.absolutePosition.y
        var maxX = first.absolutePosition.x
        var maxY = first.absolutePosition.y
        for pin in net.pins.dropFirst() {
            minX = min(minX, pin.absolutePosition.x)
            minY = min(minY, pin.absolutePosition.y)
            maxX = max(maxX, pin.absolutePosition.x)
            maxY = max(maxY, pin.absolutePosition.y)
        }
        return (maxX - minX) + (maxY - minY)
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

    private func computeRoutingBoundingBox(
        nets: [RoutingNet],
        obstructions: [LayoutShape]
    ) -> LayoutRect {
        var bbox: LayoutRect?
        for net in nets {
            for pin in net.pins {
                let rect = LayoutRect(
                    origin: pin.absolutePosition,
                    size: LayoutSize(width: 0.01, height: 0.01)
                )
                bbox = bbox.map { $0.union(rect) } ?? rect
            }
        }
        for obstruction in obstructions {
            let rect = boundingRect(obstruction)
            bbox = bbox.map { $0.union(rect) } ?? rect
        }
        return bbox?.expanded(by: 20.0, 20.0) ?? LayoutRect(
            origin: LayoutPoint(x: -20.0, y: -20.0),
            size: LayoutSize(width: 40.0, height: 40.0)
        )
    }

    // MARK: - Edge Routing

    private func routeEdge(
        netID: UUID,
        from: LayoutPoint,
        to: LayoutPoint,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        tech: LayoutTechDatabase,
        congestion: CongestionGrid,
        obstMap: inout ObstructionMap
    ) throws -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        // Same point
        if abs(from.x - to.x) < grid && abs(from.y - to.y) < grid {
            return ([], [])
        }

        // Horizontal only (same Y). Use an M2 trunk so the route does not
        // short across unrelated M1 device pads between the endpoints.
        if abs(from.y - to.y) < grid {
            var shapes: [LayoutShape] = []
            var vias: [LayoutVia] = []
            let h = makeHorizontal(from: from, to: to, layer: m2ID, width: m2Width, grid: grid, netID: netID)
            let candidateShapes = makeViaLandingShapes(at: from, viaDef: viaDef, grid: grid, netID: netID)
                + [h]
                + makeViaLandingShapes(at: to, viaDef: viaDef, grid: grid, netID: netID)
            guard !hasCollision(
                shapes: candidateShapes,
                m1ID: m1ID,
                m2ID: m2ID,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                obstacleMap: obstMap,
                ignoringNetID: netID
            ) else {
                let trackPitch = max(m2Width + m2Spacing, grid)
                for midY in zTrackCandidates(from: from.y, to: to.y, pitch: trackPitch, grid: grid) {
                    if let result = routeM2HorizontalDogleg(
                        from: from, to: to, midY: midY,
                        netID: netID,
                        m1ID: m1ID, m2ID: m2ID,
                        m1Spacing: m1Spacing, m2Spacing: m2Spacing,
                        m2Width: m2Width,
                        viaDef: viaDef, grid: grid, obstMap: &obstMap
                    ) {
                        return result
                    }
                }
                return try routeMazeFallback(
                    from: from,
                    to: to,
                    netID: netID,
                    m1ID: m1ID,
                    m2ID: m2ID,
                    m1Spacing: m1Spacing,
                    m2Spacing: m2Spacing,
                    viaDef: viaDef,
                    grid: grid,
                    tech: tech,
                    congestion: congestion,
                    obstMap: &obstMap
                )
            }
            appendVia(at: from, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
            obstMap.register(shape: h)
            shapes.append(h)
            appendVia(at: to, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
            registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)
            return (shapes, vias)
        }

        // Vertical only (same X) — need VIA at both ends since pins are on M1
        if abs(from.x - to.x) < grid {
            return routeVerticalWithVias(
                from: from, to: to,
                netID: netID,
                m1ID: m1ID, m2ID: m2ID,
                m1Width: m1Width, m2Width: m2Width,
                m1Spacing: m1Spacing, m2Spacing: m2Spacing,
                viaDef: viaDef, grid: grid, obstMap: &obstMap
            )
        }

        // L-shape attempt 1: M1 horizontal(from→bend) → VIA → M2 vertical(bend→to) → VIA at to
        let bend1 = LayoutPoint(x: to.x, y: from.y)
        if let result = routeLShape(
            from: from, bend: bend1, to: to,
            netID: netID,
            m1ID: m1ID, m2ID: m2ID,
            m1Width: m1Width, m2Width: m2Width,
            m1Spacing: m1Spacing, m2Spacing: m2Spacing,
            viaDef: viaDef, grid: grid, obstMap: &obstMap
        ) {
            return result
        }

        // L-shape attempt 2: VIA at from → M2 vertical(from→bend) → VIA → M1 horizontal(bend→to)
        let bend2 = LayoutPoint(x: from.x, y: to.y)
        if let result = routeLShape(
            from: from, bend: bend2, to: to,
            netID: netID,
            m1ID: m1ID, m2ID: m2ID,
            m1Width: m1Width, m2Width: m2Width,
            m1Spacing: m1Spacing, m2Spacing: m2Spacing,
            viaDef: viaDef, grid: grid, obstMap: &obstMap
        ) {
            return result
        }

        // Z-shape fallback across candidate vertical tracks.
        let trackPitch = max(m2Width + m2Spacing, grid)
        for midX in zTrackCandidates(from: from.x, to: to.x, pitch: trackPitch, grid: grid) {
            if let result = routeZShape(
                from: from, to: to, midX: midX,
                netID: netID,
                m1ID: m1ID, m2ID: m2ID,
                m1Width: m1Width, m2Width: m2Width,
                m1Spacing: m1Spacing, m2Spacing: m2Spacing,
                viaDef: viaDef, grid: grid, obstMap: &obstMap
            ) {
                return result
            }
        }
        for midX in zTrackCandidates(from: from.x, to: to.x, pitch: trackPitch, grid: grid) {
            if let result = routeM2Dogleg(
                from: from, to: to, midX: midX,
                netID: netID,
                m1ID: m1ID, m2ID: m2ID,
                m1Spacing: m1Spacing, m2Spacing: m2Spacing,
                m2Width: m2Width,
                viaDef: viaDef, grid: grid, obstMap: &obstMap
            ) {
                return result
            }
        }
        for midY in zTrackCandidates(from: from.y, to: to.y, pitch: trackPitch, grid: grid) {
            if let result = routeM2HorizontalDogleg(
                from: from, to: to, midY: midY,
                netID: netID,
                m1ID: m1ID, m2ID: m2ID,
                m1Spacing: m1Spacing, m2Spacing: m2Spacing,
                m2Width: m2Width,
                viaDef: viaDef, grid: grid, obstMap: &obstMap
            ) {
                return result
            }
        }
        return try routeMazeFallback(
            from: from,
            to: to,
            netID: netID,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            viaDef: viaDef,
            grid: grid,
            tech: tech,
            congestion: congestion,
            obstMap: &obstMap
        )
    }

    // MARK: - Shape Creation

    private func makeHorizontal(
        from: LayoutPoint,
        to: LayoutPoint,
        layer: LayoutLayerID,
        width: Double,
        grid: Double,
        netID: UUID? = nil
    ) -> LayoutShape {
        let minX = min(from.x, to.x)
        let maxX = max(from.x, to.x)
        let w = max(snap(maxX - minX, grid: grid), snap(width, grid: grid))
        let rect = LayoutRect(
            origin: LayoutPoint(x: snap(minX, grid: grid), y: snap(from.y - width / 2, grid: grid)),
            size: LayoutSize(width: w, height: snap(width, grid: grid))
        )
        return LayoutShape(layer: layer, netID: netID, geometry: .rect(rect))
    }

    private func makeVertical(
        from: LayoutPoint,
        to: LayoutPoint,
        layer: LayoutLayerID,
        width: Double,
        grid: Double,
        netID: UUID? = nil
    ) -> LayoutShape {
        let minY = min(from.y, to.y)
        let maxY = max(from.y, to.y)
        let h = max(snap(maxY - minY, grid: grid), snap(width, grid: grid))
        let rect = LayoutRect(
            origin: LayoutPoint(x: snap(from.x - width / 2, grid: grid), y: snap(minY, grid: grid)),
            size: LayoutSize(width: snap(width, grid: grid), height: h)
        )
        return LayoutShape(layer: layer, netID: netID, geometry: .rect(rect))
    }

    private func makeVia(
        at point: LayoutPoint,
        netID: UUID?,
        viaDef: LayoutViaDefinition,
        grid: Double
    ) -> LayoutVia {
        LayoutVia(
            viaDefinitionID: viaDef.id,
            position: LayoutPoint(x: snap(point.x, grid: grid), y: snap(point.y, grid: grid)),
            netID: netID
        )
    }

    private func appendVia(
        at point: LayoutPoint,
        netID: UUID,
        viaDef: LayoutViaDefinition,
        grid: Double,
        shapes: inout [LayoutShape],
        vias: inout [LayoutVia]
    ) {
        let via = makeVia(at: point, netID: netID, viaDef: viaDef, grid: grid)
        vias.append(via)
        shapes.append(contentsOf: makeViaLandingShapes(at: via.position, viaDef: viaDef, grid: grid, netID: netID))
    }

    private func makeViaLandingShapes(
        at point: LayoutPoint,
        viaDef: LayoutViaDefinition,
        grid: Double,
        netID: UUID? = nil
    ) -> [LayoutShape] {
        [
            makeViaLandingShape(
                at: point,
                layer: viaDef.bottomLayer,
                size: viaDef.cutSize.width + 2 * viaDef.enclosure.bottom,
                grid: grid,
                netID: netID
            ),
            makeViaLandingShape(
                at: point,
                layer: viaDef.topLayer,
                size: viaDef.cutSize.width + 2 * viaDef.enclosure.top,
                grid: grid,
                netID: netID
            ),
        ]
    }

    private func makeViaLandingShape(
        at point: LayoutPoint,
        layer: LayoutLayerID,
        size: Double,
        grid: Double,
        netID: UUID? = nil
    ) -> LayoutShape {
        let snappedSize = ContactArrayHelper.snapUp(size + 2 * grid, grid: grid)
        let rect = LayoutRect(
            origin: LayoutPoint(
                x: snap(point.x - snappedSize / 2, grid: grid),
                y: snap(point.y - snappedSize / 2, grid: grid)
            ),
            size: LayoutSize(width: snappedSize, height: snappedSize)
        )
        return LayoutShape(layer: layer, netID: netID, geometry: .rect(rect))
    }

    // MARK: - Vertical with VIAs (pins on M1, route on M2)

    private func routeVerticalWithVias(
        from: LayoutPoint,
        to: LayoutPoint,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        let v = makeVertical(from: from, to: to, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let candidateShapes = makeViaLandingShapes(at: from, viaDef: viaDef, grid: grid, netID: netID)
            + [v]
            + makeViaLandingShapes(at: to, viaDef: viaDef, grid: grid, netID: netID)
        guard !hasCollision(
            shapes: candidateShapes,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            obstacleMap: obstMap,
            ignoringNetID: netID
        ) else {
            return nil
        }

        // VIA at from (M1→M2)
        appendVia(at: from, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

        // M2 vertical
        obstMap.register(shape: v)
        shapes.append(v)

        // VIA at to (M2→M1)
        appendVia(at: to, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)

        return (shapes, vias)
    }

    // MARK: - L-Shape

    private func routeLShape(
        from: LayoutPoint,
        bend: LayoutPoint,
        to: LayoutPoint,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let isFirstHorizontal = abs(from.y - bend.y) < grid

        // Check collision on each segment before committing
        if isFirstHorizontal {
            let hShape = makeHorizontal(from: from, to: bend, layer: m1ID, width: m1Width, grid: grid, netID: netID)
            let vShape = makeVertical(from: bend, to: to, layer: m2ID, width: m2Width, grid: grid, netID: netID)
            let candidateShapes = [hShape]
                + makeViaLandingShapes(at: bend, viaDef: viaDef, grid: grid, netID: netID)
                + [vShape]
                + makeViaLandingShapes(at: to, viaDef: viaDef, grid: grid, netID: netID)

            if hasCollision(
                shapes: candidateShapes,
                m1ID: m1ID,
                m2ID: m2ID,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                obstacleMap: obstMap,
                ignoringNetID: netID
            ) {
                return nil
            }

            var shapes: [LayoutShape] = []
            var vias: [LayoutVia] = []

            // M1 horizontal from → bend (from pin is on M1, no VIA needed at from)
            obstMap.register(shape: hShape)
            shapes.append(hShape)

            // VIA at bend (M1→M2)
            appendVia(at: bend, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

            // M2 vertical bend → to
            obstMap.register(shape: vShape)
            shapes.append(vShape)

            // VIA at to (M2→M1, since destination pin is on M1)
            appendVia(at: to, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
            registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)

            return (shapes, vias)
        } else {
            // First segment is vertical (from → bend)
            let vShape = makeVertical(from: from, to: bend, layer: m2ID, width: m2Width, grid: grid, netID: netID)
            let hShape = makeHorizontal(from: bend, to: to, layer: m1ID, width: m1Width, grid: grid, netID: netID)
            let candidateShapes = makeViaLandingShapes(at: from, viaDef: viaDef, grid: grid, netID: netID)
                + [vShape]
                + makeViaLandingShapes(at: bend, viaDef: viaDef, grid: grid, netID: netID)
                + [hShape]

            if hasCollision(
                shapes: candidateShapes,
                m1ID: m1ID,
                m2ID: m2ID,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                obstacleMap: obstMap,
                ignoringNetID: netID
            ) {
                return nil
            }

            var shapes: [LayoutShape] = []
            var vias: [LayoutVia] = []

            // VIA at from (M1→M2, since source pin is on M1)
            appendVia(at: from, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

            // M2 vertical from → bend
            obstMap.register(shape: vShape)
            shapes.append(vShape)

            // VIA at bend (M2→M1)
            appendVia(at: bend, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

            // M1 horizontal bend → to (to pin is on M1, no VIA needed)
            obstMap.register(shape: hShape)
            shapes.append(hShape)
            registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)

            return (shapes, vias)
        }
    }

    // MARK: - Z-Shape

    private func routeZShape(
        from: LayoutPoint,
        to: LayoutPoint,
        midX: Double,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let bend1 = LayoutPoint(x: midX, y: from.y)
        let bend2 = LayoutPoint(x: midX, y: to.y)

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []

        // M1 horizontal from → bend1
        let h1 = makeHorizontal(from: from, to: bend1, layer: m1ID, width: m1Width, grid: grid, netID: netID)
        let v = makeVertical(from: bend1, to: bend2, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let h2 = makeHorizontal(from: bend2, to: to, layer: m1ID, width: m1Width, grid: grid, netID: netID)
        let candidateShapes = [h1]
            + makeViaLandingShapes(at: bend1, viaDef: viaDef, grid: grid, netID: netID)
            + [v]
            + makeViaLandingShapes(at: bend2, viaDef: viaDef, grid: grid, netID: netID)
            + [h2]
        guard !hasCollision(
            shapes: candidateShapes,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            obstacleMap: obstMap,
            ignoringNetID: netID
        ) else {
            return nil
        }
        obstMap.register(shape: h1)
        shapes.append(h1)

        // VIA at bend1 (M1→M2)
        appendVia(at: bend1, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

        // M2 vertical bend1 → bend2
        obstMap.register(shape: v)
        shapes.append(v)

        // VIA at bend2 (M2→M1)
        appendVia(at: bend2, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)

        // M1 horizontal bend2 → to
        obstMap.register(shape: h2)
        shapes.append(h2)
        registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)

        return (shapes, vias)
    }

    // MARK: - M2 Dogleg

    private func routeM2Dogleg(
        from: LayoutPoint,
        to: LayoutPoint,
        midX: Double,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Spacing: Double,
        m2Spacing: Double,
        m2Width: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let bend1 = LayoutPoint(x: midX, y: from.y)
        let bend2 = LayoutPoint(x: midX, y: to.y)
        let h1 = makeHorizontal(from: from, to: bend1, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let v = makeVertical(from: bend1, to: bend2, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let h2 = makeHorizontal(from: bend2, to: to, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let candidateShapes = makeViaLandingShapes(at: from, viaDef: viaDef, grid: grid, netID: netID)
            + [h1, v, h2]
            + makeViaLandingShapes(at: to, viaDef: viaDef, grid: grid, netID: netID)
        guard !hasCollision(
            shapes: candidateShapes,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            obstacleMap: obstMap,
            ignoringNetID: netID
        ) else {
            return nil
        }

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        appendVia(at: from, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        for shape in [h1, v, h2] {
            obstMap.register(shape: shape)
            shapes.append(shape)
        }
        appendVia(at: to, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)
        return (shapes, vias)
    }

    private func routeM2HorizontalDogleg(
        from: LayoutPoint,
        to: LayoutPoint,
        midY: Double,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Spacing: Double,
        m2Spacing: Double,
        m2Width: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let bend1 = LayoutPoint(x: from.x, y: midY)
        let bend2 = LayoutPoint(x: to.x, y: midY)
        let v1 = makeVertical(from: from, to: bend1, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let h = makeHorizontal(from: bend1, to: bend2, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let v2 = makeVertical(from: bend2, to: to, layer: m2ID, width: m2Width, grid: grid, netID: netID)
        let candidateShapes = makeViaLandingShapes(at: from, viaDef: viaDef, grid: grid, netID: netID)
            + [v1, h, v2]
            + makeViaLandingShapes(at: to, viaDef: viaDef, grid: grid, netID: netID)
        guard !hasCollision(
            shapes: candidateShapes,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            obstacleMap: obstMap,
            ignoringNetID: netID
        ) else {
            return nil
        }

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        appendVia(at: from, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        for shape in [v1, h, v2] {
            obstMap.register(shape: shape)
            shapes.append(shape)
        }
        appendVia(at: to, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)
        return (shapes, vias)
    }

    // MARK: - External M2 Trunk

    private func routeExternalM2Trunk(
        net: RoutingNet,
        routingBounds: LayoutRect,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m2Width: Double,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        guard net.pins.count >= 3 else { return nil }
        let pins = net.pins.map(\.absolutePosition)
        guard let first = pins.first else { return nil }
        let minX = pins.dropFirst().reduce(first.x) { min($0, $1.x) }
        let maxX = pins.dropFirst().reduce(first.x) { max($0, $1.x) }
        let minY = pins.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxY = pins.dropFirst().reduce(first.y) { max($0, $1.y) }
        let pitch = max(m2Width + m2Spacing, grid)
        let centerX = (minX + maxX) / 2
        let boundsMinY = routingBounds.origin.y
        let boundsMaxY = routingBounds.origin.y + routingBounds.size.height
        let candidateYs = externalTrunkCandidates(
            minY: minY,
            maxY: maxY,
            boundsMinY: boundsMinY,
            boundsMaxY: boundsMaxY,
            pitch: pitch,
            grid: grid
        )

        for trunkY in candidateYs {
            for accessOffset in externalAccessOffsets(pitch: pitch, grid: grid) {
                let leftAccessX = snap(minX - accessOffset, grid: grid)
                let rightAccessX = snap(maxX + accessOffset, grid: grid)
                let trunkShape = makeHorizontal(
                    from: LayoutPoint(x: leftAccessX, y: trunkY),
                    to: LayoutPoint(x: rightAccessX, y: trunkY),
                    layer: m2ID,
                    width: m2Width,
                    grid: grid,
                    netID: net.id
                )
                let accessShapes = pins.flatMap { pin -> [LayoutShape] in
                    let accessX = pin.x <= centerX ? leftAccessX : rightAccessX
                    let accessPoint = LayoutPoint(x: accessX, y: pin.y)
                    return [
                        makeHorizontal(
                            from: pin,
                            to: accessPoint,
                            layer: m2ID,
                            width: m2Width,
                            grid: grid,
                            netID: net.id
                        ),
                        makeVertical(
                            from: accessPoint,
                            to: LayoutPoint(x: accessX, y: trunkY),
                            layer: m2ID,
                            width: m2Width,
                            grid: grid,
                            netID: net.id
                        ),
                    ]
                }
                let viaLandings = pins.flatMap {
                    makeViaLandingShapes(at: $0, viaDef: viaDef, grid: grid, netID: net.id)
                }
                let candidateShapes = viaLandings + accessShapes + [trunkShape]
                guard !hasCollision(
                    shapes: candidateShapes,
                    m1ID: m1ID,
                    m2ID: m2ID,
                    m1Spacing: m1Spacing,
                    m2Spacing: m2Spacing,
                    obstacleMap: obstMap,
                    ignoringNetID: net.id
                ) else {
                    continue
                }

                var shapes: [LayoutShape] = []
                var vias: [LayoutVia] = []
                for pin in pins {
                    appendVia(at: pin, netID: net.id, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
                }
                for shape in accessShapes + [trunkShape] {
                    shapes.append(shape)
                }
                registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)
                return (shapes, vias)
            }
        }
        return nil
    }

    /// Adds redundant stitch vias where same-net M1 and M2 geometry crosses.
    ///
    /// Route primitives insert their own vias at every layer transition, so
    /// net connectivity never depends on these stitches: any candidate that
    /// would collide with another net or leave a sub-spacing sliver against
    /// its own net is simply skipped. Crossings are stitched once per
    /// connected crossing region, not once per shape pair, so overlapping
    /// pads never spawn via farms.
    private func addLayerCrossingVias(
        to routedNet: inout RoutedNet,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) {
        let m1Shapes = routedNet.shapes.filter { $0.layer == m1ID }
        let m2Shapes = routedNet.shapes.filter { $0.layer == m2ID }
        var crossings: [LayoutRect] = []
        for m1Shape in m1Shapes {
            let m1Rect = boundingRect(m1Shape)
            for m2Shape in m2Shapes {
                if let overlap = positiveIntersection(m1Rect, boundingRect(m2Shape)) {
                    crossings.append(overlap)
                }
            }
        }
        guard !crossings.isEmpty else { return }

        let viaPositions = routedNet.vias.map(\.position)
        var existingViaKeys = Set(routedNet.vias.map { pointKey($0.position) })
        for cluster in clusterTouchingRects(crossings) {
            let alreadyStitched = viaPositions.contains { position in
                cluster.contains { rectContains($0, position) }
            }
            if alreadyStitched { continue }
            guard let anchor = cluster.max(by: { rectArea($0) < rectArea($1) }) else { continue }
            let point = snap2D(anchor.center, grid: grid)
            guard existingViaKeys.insert(pointKey(point)).inserted else { continue }
            let viaLandings = makeViaLandingShapes(
                at: point,
                viaDef: viaDef,
                grid: grid,
                netID: netID
            )
            guard !hasCollision(
                shapes: viaLandings,
                m1ID: m1ID,
                m2ID: m2ID,
                m1Spacing: m1Spacing,
                m2Spacing: m2Spacing,
                obstacleMap: obstMap,
                ignoringNetID: netID
            ) else {
                continue
            }
            appendVia(at: point, netID: netID, viaDef: viaDef, grid: grid, shapes: &routedNet.shapes, vias: &routedNet.vias)
            registerRecentViaLandings(in: routedNet.shapes, obstacleMap: &obstMap)
        }
    }

    /// Groups rects into clusters of transitively touching or overlapping
    /// rects (union-find).
    private func clusterTouchingRects(_ rects: [LayoutRect]) -> [[LayoutRect]] {
        var parent = Array(0..<rects.count)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rectSeparation(rects[i], rects[j]) <= 1.0e-9 {
                let ri = find(i)
                let rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        var groups: [Int: [LayoutRect]] = [:]
        for (i, rect) in rects.enumerated() {
            groups[find(i), default: []].append(rect)
        }
        return Array(groups.values)
    }

    /// Euclidean gap between two axis-aligned rects; 0 when they touch or overlap.
    private func rectSeparation(_ a: LayoutRect, _ b: LayoutRect) -> Double {
        let dx = max(0, max(b.origin.x - (a.origin.x + a.size.width), a.origin.x - (b.origin.x + b.size.width)))
        let dy = max(0, max(b.origin.y - (a.origin.y + a.size.height), a.origin.y - (b.origin.y + b.size.height)))
        return (dx * dx + dy * dy).squareRoot()
    }

    private func rectContains(_ rect: LayoutRect, _ point: LayoutPoint) -> Bool {
        point.x >= rect.origin.x - 1.0e-9
            && point.x <= rect.origin.x + rect.size.width + 1.0e-9
            && point.y >= rect.origin.y - 1.0e-9
            && point.y <= rect.origin.y + rect.size.height + 1.0e-9
    }

    private func rectArea(_ rect: LayoutRect) -> Double {
        rect.size.width * rect.size.height
    }

    private func positiveIntersection(_ lhs: LayoutRect, _ rhs: LayoutRect) -> LayoutRect? {
        let minX = max(lhs.origin.x, rhs.origin.x)
        let minY = max(lhs.origin.y, rhs.origin.y)
        let maxX = min(lhs.origin.x + lhs.size.width, rhs.origin.x + rhs.size.width)
        let maxY = min(lhs.origin.y + lhs.size.height, rhs.origin.y + rhs.size.height)
        guard maxX > minX, maxY > minY else { return nil }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func pointKey(_ point: LayoutPoint) -> String {
        "\(Int64((point.x * 1000).rounded()))_\(Int64((point.y * 1000).rounded()))"
    }

    private func externalAccessOffsets(pitch: Double, grid: Double) -> [Double] {
        (2...24).map { snap(Double($0) * pitch, grid: grid) }
    }

    private func externalTrunkCandidates(
        minY: Double,
        maxY: Double,
        boundsMinY: Double,
        boundsMaxY: Double,
        pitch: Double,
        grid: Double
    ) -> [Double] {
        var candidates: [Double] = []
        for step in 2...24 {
            let offset = Double(step) * pitch
            candidates.append(snap(maxY + offset, grid: grid))
            candidates.append(snap(minY - offset, grid: grid))
        }
        candidates.append(snap(boundsMaxY, grid: grid))
        candidates.append(snap(boundsMinY, grid: grid))
        var seen = Set<Double>()
        return candidates.filter { seen.insert($0).inserted }
    }

    // MARK: - Maze Fallback

    private func routeMazeFallback(
        from: LayoutPoint,
        to: LayoutPoint,
        netID: UUID,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Spacing: Double,
        m2Spacing: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        tech: LayoutTechDatabase,
        congestion: CongestionGrid,
        obstMap: inout ObstructionMap
    ) throws -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let router = MazeRouter()
        guard let segments = try router.route(
            from: snap2D(from, grid: grid),
            to: snap2D(to, grid: grid),
            layers: (m1: m1ID, m2: m2ID),
            congestion: congestion,
            obstMap: obstMap,
            tech: tech,
            ignoringNetID: netID
        ), !segments.isEmpty else {
            return nil
        }

        let routeShapes = segments.map { segmentToShape($0, netID: netID, grid: grid) }
        var viaPoints = mazeViaPoints(
            from: from,
            to: to,
            segments: segments,
            m1ID: m1ID,
            grid: grid
        )
        viaPoints = deduplicatePoints(viaPoints)

        let candidateShapes = viaPoints.flatMap {
            makeViaLandingShapes(at: $0, viaDef: viaDef, grid: grid, netID: netID)
        } + routeShapes

        guard !hasCollision(
            shapes: candidateShapes,
            m1ID: m1ID,
            m2ID: m2ID,
            m1Spacing: m1Spacing,
            m2Spacing: m2Spacing,
            obstacleMap: obstMap,
            ignoringNetID: netID
        ) else {
            return nil
        }

        var vias: [LayoutVia] = []
        var shapes: [LayoutShape] = []
        for point in viaPoints {
            appendVia(at: point, netID: netID, viaDef: viaDef, grid: grid, shapes: &shapes, vias: &vias)
        }
        for shape in routeShapes {
            obstMap.register(shape: shape)
            shapes.append(shape)
        }
        registerViaLandings(in: candidateShapes, obstacleMap: &obstMap)
        return (shapes, vias)
    }

    private func segmentToShape(
        _ segment: ChannelRouter.RouteSegment,
        netID: UUID,
        grid: Double
    ) -> LayoutShape {
        if segment.isHorizontal {
            return makeHorizontal(
                from: segment.from,
                to: segment.to,
                layer: segment.layer,
                width: segment.width,
                grid: grid,
                netID: netID
            )
        }
        return makeVertical(
            from: segment.from,
            to: segment.to,
            layer: segment.layer,
            width: segment.width,
            grid: grid,
            netID: netID
        )
    }

    private func mazeViaPoints(
        from: LayoutPoint,
        to: LayoutPoint,
        segments: [ChannelRouter.RouteSegment],
        m1ID: LayoutLayerID,
        grid: Double
    ) -> [LayoutPoint] {
        guard let first = segments.first, let last = segments.last else { return [] }
        var points: [LayoutPoint] = []
        if first.layer != m1ID {
            points.append(snap2D(from, grid: grid))
        }
        for index in 1..<segments.count {
            let previous = segments[index - 1]
            let current = segments[index]
            if previous.layer != current.layer {
                points.append(current.from)
            }
        }
        if last.layer != m1ID {
            points.append(snap2D(to, grid: grid))
        }
        return points
    }

    // MARK: - Helpers

    private func snap2D(_ point: LayoutPoint, grid: Double) -> LayoutPoint {
        LayoutPoint(x: snap(point.x, grid: grid), y: snap(point.y, grid: grid))
    }

    private func deduplicatePoints(_ points: [LayoutPoint]) -> [LayoutPoint] {
        var result: [LayoutPoint] = []
        var seen: Set<String> = []
        for point in points {
            let key = "\(Int64((point.x * 1000).rounded()))_\(Int64((point.y * 1000).rounded()))"
            if seen.insert(key).inserted {
                result.append(point)
            }
        }
        return result
    }

    private func zTrackCandidates(from fromX: Double, to toX: Double, pitch: Double, grid: Double) -> [Double] {
        let minX = min(fromX, toX)
        let maxX = max(fromX, toX)
        let center = snap((fromX + toX) / 2, grid: grid)
        var candidates: [Double] = [center]
        for step in 1...40 {
            let offset = Double(step) * pitch
            candidates.append(snap(minX - offset, grid: grid))
            candidates.append(snap(maxX + offset, grid: grid))
            candidates.append(snap(center - offset, grid: grid))
            candidates.append(snap(center + offset, grid: grid))
        }
        var seen = Set<Double>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func hasCollision(
        shapes: [LayoutShape],
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Spacing: Double,
        m2Spacing: Double,
        obstacleMap: ObstructionMap,
        ignoringNetID: UUID
    ) -> Bool {
        shapes.contains { shape in
            let spacing: Double
            if shape.layer == m1ID {
                spacing = m1Spacing
            } else if shape.layer == m2ID {
                spacing = m2Spacing
            } else {
                spacing = min(m1Spacing, m2Spacing)
            }
            let rect = boundingRect(shape)
            if obstacleMap.hasCollision(
                rect: rect,
                layer: shape.layer,
                spacing: spacing,
                ignoringNetID: ignoringNetID
            ) {
                return true
            }
            // Same-net geometry must either merge (touch) or keep the full
            // spacing; a sub-spacing gap is a sliver that spacing DRC
            // rejects regardless of net.
            return obstacleMap.hasSameNetSliver(
                rect: rect,
                layer: shape.layer,
                spacing: spacing,
                netID: ignoringNetID
            )
        }
    }

    private func registerRecentViaLandings(
        in shapes: [LayoutShape],
        obstacleMap: inout ObstructionMap
    ) {
        registerViaLandings(in: Array(shapes.suffix(2)), obstacleMap: &obstacleMap)
    }

    private func registerViaLandings(
        in shapes: [LayoutShape],
        obstacleMap: inout ObstructionMap
    ) {
        for shape in shapes {
            obstacleMap.register(shape: shape)
        }
    }

    private func boundingRect(_ shape: LayoutShape) -> LayoutRect {
        switch shape.geometry {
        case .rect(let r): return r
        case .polygon(let p):
            guard let first = p.points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x); minY = min(minY, pt.y)
                maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
            }
            return LayoutRect(origin: LayoutPoint(x: minX, y: minY),
                              size: LayoutSize(width: maxX - minX, height: maxY - minY))
        case .path(let p):
            guard let first = p.points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x); minY = min(minY, pt.y)
                maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
            }
            let hw = p.width / 2
            return LayoutRect(origin: LayoutPoint(x: minX - hw, y: minY - hw),
                              size: LayoutSize(width: maxX - minX + p.width, height: maxY - minY + p.width))
        }
    }

    private func snap(_ value: Double, grid: Double) -> Double {
        (value / grid).rounded() * grid
    }
}
