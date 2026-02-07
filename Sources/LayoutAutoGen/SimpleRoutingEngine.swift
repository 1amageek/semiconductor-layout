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
    ) -> RoutingResult {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2ID = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Rules = tech.ruleSet(for: m1ID)
        let m2Rules = tech.ruleSet(for: m2ID)
        let m1Width = m1Rules?.minWidth ?? 0.23
        let m2Width = m2Rules?.minWidth ?? 0.28
        let m1Spacing = m1Rules?.minSpacing ?? 0.23
        let m2Spacing = m2Rules?.minSpacing ?? 0.28
        let grid = tech.grid

        guard let viaDef = tech.vias.first else {
            return RoutingResult(
                routes: [],
                unroutedNets: nets.map(\.name)
            )
        }

        var obstMap = ObstructionMap()
        for obs in obstructions {
            obstMap.register(shape: obs)
        }

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

        for net in nets {
            guard net.pins.count >= 1 else { continue }

            if net.isPower {
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

                let result = routeEdge(
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
                    obstMap: &obstMap
                )

                if let (shapes, vias) = result {
                    routedNet.shapes.append(contentsOf: shapes)
                    routedNet.vias.append(contentsOf: vias)
                } else {
                    allRouted = false
                }
            }

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
                routedNet.vias.append(makeVia(at: pinPos, viaDef: viaDef, grid: grid))
                continue
            }

            // VIA at pin (M1→M2)
            routedNet.vias.append(makeVia(at: pinPos, viaDef: viaDef, grid: grid))

            // M2 vertical from pin to rail
            let v = makeVertical(
                from: pinPos, to: railPoint, layer: m2ID, width: m2Width, grid: grid
            )
            obstMap.register(shape: v)
            routedNet.shapes.append(v)

            // VIA at rail (M2→M1)
            routedNet.vias.append(makeVia(at: railPoint, viaDef: viaDef, grid: grid))
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

    // MARK: - Edge Routing

    private func routeEdge(
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
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        // Same point
        if abs(from.x - to.x) < grid && abs(from.y - to.y) < grid {
            return ([], [])
        }

        // Horizontal only (same Y) — pure M1, no VIA needed since pins are on M1
        if abs(from.y - to.y) < grid {
            let h = makeHorizontal(from: from, to: to, layer: m1ID, width: m1Width, grid: grid)
            obstMap.register(shape: h)
            return ([h], [])
        }

        // Vertical only (same X) — need VIA at both ends since pins are on M1
        if abs(from.x - to.x) < grid {
            return routeVerticalWithVias(
                from: from, to: to,
                m1ID: m1ID, m2ID: m2ID,
                m1Width: m1Width, m2Width: m2Width,
                viaDef: viaDef, grid: grid, obstMap: &obstMap
            )
        }

        // L-shape attempt 1: M1 horizontal(from→bend) → VIA → M2 vertical(bend→to) → VIA at to
        let bend1 = LayoutPoint(x: to.x, y: from.y)
        if let result = routeLShape(
            from: from, bend: bend1, to: to,
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
            m1ID: m1ID, m2ID: m2ID,
            m1Width: m1Width, m2Width: m2Width,
            m1Spacing: m1Spacing, m2Spacing: m2Spacing,
            viaDef: viaDef, grid: grid, obstMap: &obstMap
        ) {
            return result
        }

        // Z-shape fallback
        let midX = snap((from.x + to.x) / 2, grid: grid)
        return routeZShape(
            from: from, to: to, midX: midX,
            m1ID: m1ID, m2ID: m2ID,
            m1Width: m1Width, m2Width: m2Width,
            viaDef: viaDef, grid: grid, obstMap: &obstMap
        )
    }

    // MARK: - Shape Creation

    private func makeHorizontal(
        from: LayoutPoint,
        to: LayoutPoint,
        layer: LayoutLayerID,
        width: Double,
        grid: Double
    ) -> LayoutShape {
        let minX = min(from.x, to.x)
        let maxX = max(from.x, to.x)
        let w = max(snap(maxX - minX, grid: grid), snap(width, grid: grid))
        let rect = LayoutRect(
            origin: LayoutPoint(x: snap(minX, grid: grid), y: snap(from.y - width / 2, grid: grid)),
            size: LayoutSize(width: w, height: snap(width, grid: grid))
        )
        return LayoutShape(layer: layer, geometry: .rect(rect))
    }

    private func makeVertical(
        from: LayoutPoint,
        to: LayoutPoint,
        layer: LayoutLayerID,
        width: Double,
        grid: Double
    ) -> LayoutShape {
        let minY = min(from.y, to.y)
        let maxY = max(from.y, to.y)
        let h = max(snap(maxY - minY, grid: grid), snap(width, grid: grid))
        let rect = LayoutRect(
            origin: LayoutPoint(x: snap(from.x - width / 2, grid: grid), y: snap(minY, grid: grid)),
            size: LayoutSize(width: snap(width, grid: grid), height: h)
        )
        return LayoutShape(layer: layer, geometry: .rect(rect))
    }

    private func makeVia(
        at point: LayoutPoint,
        viaDef: LayoutViaDefinition,
        grid: Double
    ) -> LayoutVia {
        LayoutVia(
            viaDefinitionID: viaDef.id,
            position: LayoutPoint(x: snap(point.x, grid: grid), y: snap(point.y, grid: grid))
        )
    }

    // MARK: - Vertical with VIAs (pins on M1, route on M2)

    private func routeVerticalWithVias(
        from: LayoutPoint,
        to: LayoutPoint,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia]) {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []

        // VIA at from (M1→M2)
        vias.append(makeVia(at: from, viaDef: viaDef, grid: grid))

        // M2 vertical
        let v = makeVertical(from: from, to: to, layer: m2ID, width: m2Width, grid: grid)
        obstMap.register(shape: v)
        shapes.append(v)

        // VIA at to (M2→M1)
        vias.append(makeVia(at: to, viaDef: viaDef, grid: grid))

        return (shapes, vias)
    }

    // MARK: - L-Shape

    private func routeLShape(
        from: LayoutPoint,
        bend: LayoutPoint,
        to: LayoutPoint,
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
            let hShape = makeHorizontal(from: from, to: bend, layer: m1ID, width: m1Width, grid: grid)
            let vShape = makeVertical(from: bend, to: to, layer: m2ID, width: m2Width, grid: grid)

            if obstMap.hasCollision(rect: boundingRect(hShape), layer: m1ID, spacing: m1Spacing)
                || obstMap.hasCollision(rect: boundingRect(vShape), layer: m2ID, spacing: m2Spacing) {
                return nil
            }

            var shapes: [LayoutShape] = []
            var vias: [LayoutVia] = []

            // M1 horizontal from → bend (from pin is on M1, no VIA needed at from)
            obstMap.register(shape: hShape)
            shapes.append(hShape)

            // VIA at bend (M1→M2)
            vias.append(makeVia(at: bend, viaDef: viaDef, grid: grid))

            // M2 vertical bend → to
            obstMap.register(shape: vShape)
            shapes.append(vShape)

            // VIA at to (M2→M1, since destination pin is on M1)
            vias.append(makeVia(at: to, viaDef: viaDef, grid: grid))

            return (shapes, vias)
        } else {
            // First segment is vertical (from → bend)
            let vShape = makeVertical(from: from, to: bend, layer: m2ID, width: m2Width, grid: grid)
            let hShape = makeHorizontal(from: bend, to: to, layer: m1ID, width: m1Width, grid: grid)

            if obstMap.hasCollision(rect: boundingRect(vShape), layer: m2ID, spacing: m2Spacing)
                || obstMap.hasCollision(rect: boundingRect(hShape), layer: m1ID, spacing: m1Spacing) {
                return nil
            }

            var shapes: [LayoutShape] = []
            var vias: [LayoutVia] = []

            // VIA at from (M1→M2, since source pin is on M1)
            vias.append(makeVia(at: from, viaDef: viaDef, grid: grid))

            // M2 vertical from → bend
            obstMap.register(shape: vShape)
            shapes.append(vShape)

            // VIA at bend (M2→M1)
            vias.append(makeVia(at: bend, viaDef: viaDef, grid: grid))

            // M1 horizontal bend → to (to pin is on M1, no VIA needed)
            obstMap.register(shape: hShape)
            shapes.append(hShape)

            return (shapes, vias)
        }
    }

    // MARK: - Z-Shape

    private func routeZShape(
        from: LayoutPoint,
        to: LayoutPoint,
        midX: Double,
        m1ID: LayoutLayerID,
        m2ID: LayoutLayerID,
        m1Width: Double,
        m2Width: Double,
        viaDef: LayoutViaDefinition,
        grid: Double,
        obstMap: inout ObstructionMap
    ) -> (shapes: [LayoutShape], vias: [LayoutVia])? {
        let bend1 = LayoutPoint(x: midX, y: from.y)
        let bend2 = LayoutPoint(x: midX, y: to.y)

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []

        // M1 horizontal from → bend1
        let h1 = makeHorizontal(from: from, to: bend1, layer: m1ID, width: m1Width, grid: grid)
        obstMap.register(shape: h1)
        shapes.append(h1)

        // VIA at bend1 (M1→M2)
        vias.append(makeVia(at: bend1, viaDef: viaDef, grid: grid))

        // M2 vertical bend1 → bend2
        let v = makeVertical(from: bend1, to: bend2, layer: m2ID, width: m2Width, grid: grid)
        obstMap.register(shape: v)
        shapes.append(v)

        // VIA at bend2 (M2→M1)
        vias.append(makeVia(at: bend2, viaDef: viaDef, grid: grid))

        // M1 horizontal bend2 → to
        let h2 = makeHorizontal(from: bend2, to: to, layer: m1ID, width: m1Width, grid: grid)
        obstMap.register(shape: h2)
        shapes.append(h2)

        return (shapes, vias)
    }

    // MARK: - Helpers

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
