import Foundation
import LayoutCore
import LayoutTech

/// Label-free connectivity extraction over the flattened design.
///
/// Every captured band is a conductor element; native integer layer/cut
/// contacts establish its component membership. Connected components of that
/// contact graph are the extracted nets; comparing their members' declared
/// net labels yields shorts (one piece, several labels) and opens (one
/// label, several pieces) including the via-mediated and
/// unlabeled-bridge shorts the pairwise overlap check cannot see.
///
/// All derivation iterates canonically sorted member keys, so the live
/// session producing the same component partition emits a bit-identical
/// ``ConnectivityAnalysis``.
public struct LayoutConnectivityExtractor {
    private let service = LayoutDRCService()

    public init() {}

    /// The flattened conductor geometry of one cell — instance subtrees
    /// expanded with their transforms applied — KEEPING source element
    /// IDs, so the result cross-references the IDs a connectivity
    /// analysis reports. (Child occurrences of a multi-instanced cell
    /// share an ID by design; positions disambiguate.)
    public func flattenedConductors(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws -> (shapes: [LayoutShape], vias: [LayoutVia], pins: [LayoutPin]) {
        guard let targetCell = service.resolveCell(document: document, cellID: cellID) else {
            throw LayoutConnectivityExtractionError.targetCellNotFound
        }
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var conflicts: [LayoutDRCService.TerminalConnectivityConflict] = []
        try service.flatten(
            cell: targetCell,
            document: document,
            tech: tech,
            shapes: &shapes,
            vias: &vias,
            pins: &pins,
            terminalConflicts: &conflicts
        )
        return (shapes, vias, pins)
    }

    /// Extracts connectivity for one cell of the document, flattening
    /// child instances exactly like the DRC service does.
    public func extract(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil,
        limits: LayoutConductorCaptureLimits = .default,
        electricalContext: LayoutElectricalContext = .geometric
    ) throws -> ConnectivityAnalysis {
        guard service.resolveCell(document: document, cellID: cellID) != nil else {
            throw LayoutConnectivityExtractionError.targetCellNotFound
        }

        let snapshot = try captureElectricalConductors(document: document, tech: tech, cellID: cellID,
            limits: limits, electricalContext: electricalContext)
        return try Self.analysis(from: snapshot)
    }

    func captureElectricalConductors(document: LayoutDocument, tech: LayoutTechDatabase, cellID: UUID? = nil,
        limits: LayoutConductorCaptureLimits = .default, electricalContext: LayoutElectricalContext
    ) throws -> LayoutConductorSnapshot {
        switch electricalContext {
        case .geometric:
            return try captureConductors(document: document, tech: tech,
                conductiveLayers: Self.productionConductiveLayers(tech, limits: limits), cellID: cellID, limits: limits)
        case .deviceAwareMOS:
            return try DeviceExtractor().captureConductors(document: document, tech: tech, cellID: cellID, limits: limits)
        }
    }

    // MARK: - Native component presentation

    static func net(
        for memberKeys: [ConnectivityElementKey],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> ConnectivityNet {
        var shapeIDs: Set<UUID> = []
        var viaIDs: Set<UUID> = []
        var declared: Set<LayoutConductorSnapshot.NetReference> = []
        var box: LayoutRect?
        var footprints: [ConnectivityIslandFootprint] = []
        for key in memberKeys {
            guard let element = elements[key] else {
                continue
            }
            if element.isVia { viaIDs.insert(element.elementID) } else { shapeIDs.insert(element.elementID) }
            if let net = element.declaredNet { declared.insert(net) }
            if let layer = element.layer {
                footprints.append(ConnectivityIslandFootprint(layer: layer, boundingBox: element.boundingBox))
            }
            box = box.map { $0.union(element.boundingBox) } ?? element.boundingBox
        }
        guard let boundingBox = box else {
            return ConnectivityNet(
                shapeIDs: [], viaIDs: [], declaredNets: [],
                boundingBox: LayoutRect(origin: .zero, size: LayoutSize(width: 0, height: 0)),
                memberFootprints: [],
                memberKeys: memberKeys
            )
        }
        return ConnectivityNet(
            shapeIDs: shapeIDs.sorted { $0.isCanonicallyOrderedBefore($1) },
            viaIDs: viaIDs.sorted { $0.isCanonicallyOrderedBefore($1) },
            declaredNets: declared.sorted(),
            boundingBox: boundingBox,
            memberFootprints: footprints,
            memberKeys: memberKeys
        )
    }

    /// Shorts, opens, and flylines derived purely from the canonically
    /// ordered nets, so cached and freshly computed nets assemble to the
    /// same analysis.
    static func analysis(
        nets: [ConnectivityNet],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> ConnectivityAnalysis {
        var shorts: [ConnectivityShort] = []
        var componentIndicesByNet: [LayoutConductorSnapshot.NetReference: [Int]] = [:]

        for (componentIndex, net) in nets.enumerated() {
            if net.declaredNets.count >= 2 {
                shorts.append(ConnectivityShort(
                    netIDs: net.declaredNets,
                    shapeIDs: net.shapeIDs,
                    viaIDs: net.viaIDs,
                    region: net.boundingBox,
                    memberKeys: net.memberKeys
                ))
            }
            for netID in net.declaredNets {
                componentIndicesByNet[netID, default: []].append(componentIndex)
            }
        }

        var opens: [ConnectivityOpen] = []
        for netID in componentIndicesByNet.keys.sorted() {
            guard let componentIndices = componentIndicesByNet[netID] else { continue }
            guard componentIndices.count >= 2 else { continue }
            let islands = componentIndices.map { index -> ConnectivityIsland in
                let net = nets[index]
                return ConnectivityIsland(
                    shapeIDs: net.shapeIDs,
                    viaIDs: net.viaIDs,
                    boundingBox: net.boundingBox,
                    memberFootprints: net.memberFootprints,
                    memberKeys: net.memberKeys
                )
            }
            opens.append(ConnectivityOpen(
                netID: netID,
                islands: islands,
                flylines: flylines(netID: netID, islands: islands, elements: elements)
            ))
        }

        return ConnectivityAnalysis(nets: nets, shorts: shorts, opens: opens)
    }

    // MARK: - Flylines

    /// Minimum spanning tree over the open net's islands via Prim's
    /// algorithm rooted at island 0. Edge weight and endpoints are the
    /// nearest points between any two member bounding boxes of the two
    /// islands; ties resolve to the first candidate in canonical member
    /// order, so the geometry is deterministic.
    static func flylines(
        netID: LayoutConductorSnapshot.NetReference,
        islands: [ConnectivityIsland],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> [Flyline] {
        guard islands.count >= 2 else { return [] }
        let memberBoxes: [[LayoutRect]] = islands.map { island in
            island.memberKeys.compactMap { elements[$0]?.boundingBox }
        }

        struct Candidate {
            var fromIsland: Int
            var start: LayoutPoint
            var end: LayoutPoint
            var distance: Double
        }

        func bestEdge(fromTreeIsland tree: Int, to island: Int) -> Candidate {
            var best: Candidate?
            for treeBox in memberBoxes[tree] {
                for islandBox in memberBoxes[island] {
                    let near = nearestPoints(between: treeBox, and: islandBox)
                    if best.map({ near.distance < $0.distance }) ?? true {
                        best = Candidate(
                            fromIsland: tree,
                            start: near.start,
                            end: near.end,
                            distance: near.distance
                        )
                    }
                }
            }
            guard let edge = best else {
                return Candidate(fromIsland: tree, start: .zero, end: .zero, distance: .infinity)
            }
            return edge
        }

        var inTree = [Bool](repeating: false, count: islands.count)
        inTree[0] = true
        var candidate: [Candidate?] = (0..<islands.count).map { index in
            index == 0 ? nil : bestEdge(fromTreeIsland: 0, to: index)
        }

        var result: [Flyline] = []
        result.reserveCapacity(islands.count - 1)
        while result.count < islands.count - 1 {
            var pick: Int?
            for index in 0..<islands.count where !inTree[index] {
                guard let indexCandidate = candidate[index] else { continue }
                if let currentPick = pick, let currentCandidate = candidate[currentPick] {
                    if indexCandidate.distance < currentCandidate.distance {
                        pick = index
                    }
                } else {
                    pick = index
                }
            }
            guard let next = pick, let edge = candidate[next] else {
                break
            }
            result.append(Flyline(
                netID: netID,
                fromIslandIndex: edge.fromIsland,
                toIslandIndex: next,
                start: edge.start,
                end: edge.end,
                length: edge.distance
            ))
            inTree[next] = true
            candidate[next] = nil
            for index in 0..<islands.count where !inTree[index] {
                let fresh = bestEdge(fromTreeIsland: next, to: index)
                if candidate[index].map({ fresh.distance < $0.distance }) ?? true {
                    candidate[index] = fresh
                }
            }
        }
        return result
    }

    /// Nearest point pair between two axis-aligned rectangles. Overlapping
    /// extents resolve to the midpoint of the shared interval on that
    /// axis, so touching rectangles yield one shared point and distance 0.
    static func nearestPoints(
        between a: LayoutRect,
        and b: LayoutRect
    ) -> (start: LayoutPoint, end: LayoutPoint, distance: Double) {
        let x = nearestCoordinates(minA: a.minX, maxA: a.maxX, minB: b.minX, maxB: b.maxX)
        let y = nearestCoordinates(minA: a.minY, maxA: a.maxY, minB: b.minY, maxB: b.maxY)
        let distance = (x.gap * x.gap + y.gap * y.gap).squareRoot()
        return (
            start: LayoutPoint(x: x.onA, y: y.onA),
            end: LayoutPoint(x: x.onB, y: y.onB),
            distance: distance
        )
    }

    private static func nearestCoordinates(
        minA: Double, maxA: Double, minB: Double, maxB: Double
    ) -> (onA: Double, onB: Double, gap: Double) {
        if minB > maxA { return (onA: maxA, onB: minB, gap: minB - maxA) }
        if minA > maxB { return (onA: minA, onB: maxB, gap: minA - maxB) }
        let mid = (max(minA, minB) + min(maxA, maxB)) / 2
        return (onA: mid, onB: mid, gap: 0)
    }
}
