import Foundation
import LayoutCore
import LayoutTech

/// Label-free connectivity extraction over the flattened design.
///
/// Every flattened shape and via is a conductor element; two elements are
/// fused exactly when ``LayoutDRCService/shouldConnect`` says they touch
/// electrically — the same predicate the DRC open check uses, so the two
/// engines can never disagree about contact. Connected components of that
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

    /// Extracts connectivity for one cell of the document, flattening
    /// child instances exactly like the DRC service does.
    public func extract(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws -> ConnectivityAnalysis {
        guard let targetCell = service.resolveCell(document: document, cellID: cellID) else {
            throw LayoutConnectivityExtractionError.targetCellNotFound
        }

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var conflicts: [LayoutDRCService.TerminalConnectivityConflict] = []
        service.flatten(
            cell: targetCell,
            document: document,
            tech: tech,
            transforms: [],
            terminalNetIDs: [:],
            shapes: &shapes,
            vias: &vias,
            pins: &pins,
            terminalConflicts: &conflicts
        )

        let elements = Self.makeElements(
            topShapes: Array(shapes.prefix(targetCell.shapes.count)),
            childShapes: Array(shapes.dropFirst(targetCell.shapes.count)),
            topVias: Array(vias.prefix(targetCell.vias.count)),
            childVias: Array(vias.dropFirst(targetCell.vias.count)),
            tech: tech,
            service: service
        )
        let adjacency = Self.contactAdjacency(elements: elements, service: service)
        let components = Self.components(adjacency: adjacency, elements: elements)
        return Self.assemble(components: components, elements: elements)
    }

    // MARK: - Element table

    /// Builds the conductor element table in flatten order, keyed by the
    /// occurrence identities the live session also uses.
    static func makeElements(
        topShapes: [LayoutShape],
        childShapes: [LayoutShape],
        topVias: [LayoutVia],
        childVias: [LayoutVia],
        tech: LayoutTechDatabase,
        service: LayoutDRCService
    ) -> [ConnectivityElementKey: ConnectivityElement] {
        var elements: [ConnectivityElementKey: ConnectivityElement] = [:]
        elements.reserveCapacity(
            topShapes.count + childShapes.count + topVias.count + childVias.count
        )
        for shape in topShapes {
            let element = makeShapeElement(shape, key: .shape(.top(shape.id)))
            elements[element.key] = element
        }
        for (index, shape) in childShapes.enumerated() {
            let element = makeShapeElement(shape, key: .shape(.child(index)))
            elements[element.key] = element
        }
        for via in topVias {
            let element = makeViaElement(via, key: .via(.top(via.id)), tech: tech, service: service)
            elements[element.key] = element
        }
        for (index, via) in childVias.enumerated() {
            let element = makeViaElement(via, key: .via(.child(index)), tech: tech, service: service)
            elements[element.key] = element
        }
        return elements
    }

    static func makeShapeElement(_ shape: LayoutShape, key: ConnectivityElementKey) -> ConnectivityElement {
        ConnectivityElement(
            key: key,
            elementID: shape.id,
            isVia: false,
            netID: shape.netID,
            geometry: shape.geometry,
            layer: shape.layer,
            viaDefinition: nil,
            boundingBox: LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
        )
    }

    static func makeViaElement(
        _ via: LayoutVia,
        key: ConnectivityElementKey,
        tech: LayoutTechDatabase,
        service: LayoutDRCService
    ) -> ConnectivityElement {
        let cut = service.viaCutRect(for: via, tech: tech)
        return ConnectivityElement(
            key: key,
            elementID: via.id,
            isVia: true,
            netID: via.netID,
            geometry: .rect(cut),
            layer: nil,
            viaDefinition: tech.viaDefinition(for: via.viaDefinitionID),
            boundingBox: cut
        )
    }

    // MARK: - Contact graph

    /// Full pairwise contact graph over the element table, pruned by a
    /// spatial index. Symmetric: `b ∈ adjacency[a]` iff `a ∈ adjacency[b]`.
    /// Every element owns an entry, isolated ones an empty set.
    static func contactAdjacency(
        elements: [ConnectivityElementKey: ConnectivityElement],
        service: LayoutDRCService
    ) -> [ConnectivityElementKey: Set<ConnectivityElementKey>] {
        var adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>] = [:]
        adjacency.reserveCapacity(elements.count)
        for key in elements.keys { adjacency[key] = [] }
        guard elements.count > 1 else { return adjacency }

        let ordered = elements.values.sorted { $0.key < $1.key }
        let arrays = parallelArrays(for: ordered)
        let boxes = ordered.map(\.boundingBox)
        let grid = ShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
        )
        for i in 0..<(ordered.count - 1) {
            for j in grid.candidateIndices(near: boxes[i]) where j > i {
                if service.shouldConnect(
                    indexA: i,
                    indexB: j,
                    geometries: arrays.geometries,
                    layers: arrays.layers,
                    isVia: arrays.isVia,
                    viaDefs: arrays.viaDefs
                ) {
                    adjacency[ordered[i].key]!.insert(ordered[j].key)
                    adjacency[ordered[j].key]!.insert(ordered[i].key)
                }
            }
        }
        return adjacency
    }

    /// Contact set of one element against the spatial-index candidates,
    /// for the live session's edited-element re-tests. The element itself
    /// is excluded.
    static func contacts(
        of element: ConnectivityElement,
        candidates: Set<ConnectivityElementKey>,
        elements: [ConnectivityElementKey: ConnectivityElement],
        service: LayoutDRCService
    ) -> Set<ConnectivityElementKey> {
        var result: Set<ConnectivityElementKey> = []
        for key in candidates where key != element.key {
            guard let other = elements[key] else {
                assertionFailure("spatial-index candidate missing from element table")
                continue
            }
            if elementsTouch(element, other, service: service) {
                result.insert(key)
            }
        }
        return result
    }

    /// Pairwise form of the shared contact predicate. `shouldConnect`
    /// dispatches on both sides' via-ness itself, so argument order is
    /// irrelevant and this stays the same single source of truth the batch
    /// pair scan and the DRC open check use.
    static func elementsTouch(
        _ a: ConnectivityElement,
        _ b: ConnectivityElement,
        service: LayoutDRCService
    ) -> Bool {
        service.shouldConnect(
            indexA: 0,
            indexB: 1,
            geometries: [a.geometry, b.geometry],
            layers: [a.layer, b.layer],
            isVia: [a.isVia, b.isVia],
            viaDefs: [a.viaDefinition, b.viaDefinition]
        )
    }

    static func parallelArrays(for ordered: [ConnectivityElement]) -> ConnectivityParallelArrays {
        ConnectivityParallelArrays(
            geometries: ordered.map(\.geometry),
            layers: ordered.map(\.layer),
            isVia: ordered.map(\.isVia),
            viaDefs: ordered.map(\.viaDefinition)
        )
    }

    // MARK: - Components

    /// Connected components of the contact graph, each member list sorted,
    /// components ordered by their first member key.
    static func components(
        adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> [[ConnectivityElementKey]] {
        let keys = elements.keys.sorted()
        var indexByKey: [ConnectivityElementKey: Int] = [:]
        indexByKey.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() { indexByKey[key] = index }

        var unionFind = LayoutUnionFind(count: keys.count)
        for (key, neighbours) in adjacency {
            guard let a = indexByKey[key] else { continue }
            for neighbour in neighbours {
                guard let b = indexByKey[neighbour] else { continue }
                unionFind.union(a, b)
            }
        }
        return unionFind.components().values
            .map { member in member.map { keys[$0] }.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    // MARK: - Verdict assembly

    /// Derives the full analysis from canonically ordered components. Both
    /// engines call this with identical inputs for identical designs, so
    /// the emitted analyses are bit-identical.
    static func assemble(
        components: [[ConnectivityElementKey]],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> ConnectivityAnalysis {
        analysis(
            nets: components.map { net(for: $0, elements: elements) },
            elements: elements
        )
    }

    /// One conductor piece's verdict view. Split out so the live session
    /// can cache per-component nets — a component's member geometry only
    /// changes through an edit that dissolves the component, so a cached
    /// net is always exactly what this function would recompute.
    static func net(
        for memberKeys: [ConnectivityElementKey],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> ConnectivityNet {
        var shapeIDs: Set<UUID> = []
        var viaIDs: Set<UUID> = []
        var declared: Set<UUID> = []
        var box: LayoutRect?
        for key in memberKeys {
            guard let element = elements[key] else {
                assertionFailure("component member missing from element table")
                continue
            }
            if element.isVia { viaIDs.insert(element.elementID) } else { shapeIDs.insert(element.elementID) }
            if let netID = element.netID { declared.insert(netID) }
            box = box.map { $0.union(element.boundingBox) } ?? element.boundingBox
        }
        guard let boundingBox = box else {
            assertionFailure("components are never empty")
            return ConnectivityNet(
                shapeIDs: [], viaIDs: [], declaredNetIDs: [],
                boundingBox: LayoutRect(origin: .zero, size: LayoutSize(width: 0, height: 0)),
                memberKeys: memberKeys
            )
        }
        return ConnectivityNet(
            shapeIDs: shapeIDs.sorted { $0.isCanonicallyOrderedBefore($1) },
            viaIDs: viaIDs.sorted { $0.isCanonicallyOrderedBefore($1) },
            declaredNetIDs: declared.sorted { $0.isCanonicallyOrderedBefore($1) },
            boundingBox: boundingBox,
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
        var componentIndicesByNet: [UUID: [Int]] = [:]

        for (componentIndex, net) in nets.enumerated() {
            if net.declaredNetIDs.count >= 2 {
                shorts.append(ConnectivityShort(
                    netIDs: net.declaredNetIDs,
                    shapeIDs: net.shapeIDs,
                    viaIDs: net.viaIDs,
                    region: net.boundingBox,
                    memberKeys: net.memberKeys
                ))
            }
            for netID in net.declaredNetIDs {
                componentIndicesByNet[netID, default: []].append(componentIndex)
            }
        }

        var opens: [ConnectivityOpen] = []
        for netID in componentIndicesByNet.keys.sorted(by: { $0.isCanonicallyOrderedBefore($1) }) {
            let componentIndices = componentIndicesByNet[netID]!
            guard componentIndices.count >= 2 else { continue }
            let islands = componentIndices.map { index -> ConnectivityIsland in
                let net = nets[index]
                return ConnectivityIsland(
                    shapeIDs: net.shapeIDs,
                    viaIDs: net.viaIDs,
                    boundingBox: net.boundingBox,
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
        netID: UUID,
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
                    if best == nil || near.distance < best!.distance {
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
                assertionFailure("islands always have at least one member box")
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
                if pick == nil || candidate[index]!.distance < candidate[pick!]!.distance {
                    pick = index
                }
            }
            guard let next = pick, let edge = candidate[next] else {
                assertionFailure("Prim always finds a next island while the tree is incomplete")
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
                if fresh.distance < candidate[index]!.distance {
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
