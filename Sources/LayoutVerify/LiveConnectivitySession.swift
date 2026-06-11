import Foundation
import LayoutCore
import LayoutTech

/// Incremental connectivity extraction over geometry edits to one cell.
///
/// The session keeps the flattened conductor element table, the full
/// contact graph, and its connected-component partition. An edit
/// re-evaluates geometry contact only for the edited elements, then
/// re-partitions only the affected key set:
///
/// - the members of every component that contained an edited element
///   before the edit, and
/// - the members of every component an edited element touches after the
///   edit.
///
/// No contact between two unedited elements changes, and every contact of
/// an edited element stays inside that set, so unioning the induced
/// subgraph locally reproduces the global partition exactly. Verdict
/// assembly then runs through the same canonical-order path as
/// ``LayoutConnectivityExtractor``, so the analysis is bit-identical to a
/// batch extraction of the same design.
///
/// Structural changes (pins, instances, child cells, technology) are not
/// expressible as deltas; call ``rebuild(document:cellID:)``.
///
/// The session is single-owner mutable state and is not thread-safe.
public final class LiveConnectivitySession {
    private let service = LayoutDRCService()
    private let tech: LayoutTechDatabase

    // Flattened design. The target cell's own elements come first in
    // flatten order and are the editable region; contributions from
    // instantiated child cells are constant across deltas.
    private var topShapes: [LayoutShape] = []
    private var topVias: [LayoutVia] = []
    private var childShapes: [LayoutShape] = []
    private var childVias: [LayoutVia] = []
    private var childShapeIDs: Set<UUID> = []
    private var childViaIDs: Set<UUID> = []

    // Conductor element table, contact graph, and the persistent spatial
    // index that prunes edited-element contact re-tests. The index is
    // maintained across deltas — old boxes leave before the element table
    // mutates, new boxes enter after — so apply() never pays an O(n)
    // rebuild of any per-element structure.
    private var elements: [ConnectivityElementKey: ConnectivityElement] = [:]
    private var adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>] = [:]
    private var contactIndex = ConnectivityContactIndex(cellSize: 1.0)

    // Connected-component partition; member lists stay sorted. Each
    // component caches its assembled net: member geometry can only change
    // through an edit, and every edit dissolves the touched components, so
    // a cached net always equals a fresh `LayoutConnectivityExtractor.net`.
    private var membersByComponentID: [Int: [ConnectivityElementKey]] = [:]
    private var componentIDByKey: [ConnectivityElementKey: Int] = [:]
    private var netByComponentID: [Int: ConnectivityNet] = [:]
    private var nextComponentID = 0

    // Editable element positions, maintained across deltas so apply()
    // does not pay an O(n) dictionary rebuild per edit. Updates keep
    // positions, adds append; removals shift positions and trigger the
    // only full rebuild.
    private var shapeIndexByID: [UUID: Int] = [:]
    private var viaIndexByID: [UUID: Int] = [:]

    public init(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws {
        self.tech = tech
        try configure(document: document, cellID: cellID)
    }

    /// Current connectivity snapshot; always exact for the geometry the
    /// session has been fed.
    public var currentAnalysis: ConnectivityAnalysis {
        LayoutConnectivityExtractor.analysis(
            nets: netsInCanonicalOrder(),
            elements: elements
        )
    }

    /// Applies a geometry delta, re-tests contact for the edited elements,
    /// re-partitions the affected components, and returns the exact
    /// analysis.
    public func apply(_ delta: LayoutEditDelta) throws -> LiveConnectivityUpdate {
        let clock = ContinuousClock()
        let start = clock.now

        try validate(delta, shapeIndexByID: shapeIndexByID, viaIndexByID: viaIndexByID)

        let removedKeys: [ConnectivityElementKey] =
            delta.removedShapeIDs.map { .shape(.top($0)) } +
            delta.removedViaIDs.map { .via(.top($0)) }
        let updatedKeys: [ConnectivityElementKey] =
            delta.updatedShapes.map { .shape(.top($0.id)) } +
            delta.updatedVias.map { .via(.top($0.id)) }
        let addedKeys: [ConnectivityElementKey] =
            delta.addedShapes.map { .shape(.top($0.id)) } +
            delta.addedVias.map { .via(.top($0.id)) }

        // Components that contained an edited element before the edit.
        var dissolvedComponentIDs: Set<Int> = []
        for key in removedKeys + updatedKeys {
            if let componentID = componentIDByKey[key] {
                dissolvedComponentIDs.insert(componentID)
            } else {
                assertionFailure("validated existing element always has a component")
            }
        }

        // Drop the edited elements' old contacts and spatial-index entries
        // while their pre-edit bounding boxes are still known;
        // unedited-to-unedited contacts cannot change, so the rest of the
        // graph stays valid.
        for key in removedKeys + updatedKeys {
            if let element = elements[key] {
                contactIndex.remove(key, boundingBox: element.boundingBox)
            } else {
                assertionFailure("validated existing element always has a table entry")
            }
            for neighbour in adjacency[key] ?? [] {
                adjacency[neighbour]?.remove(key)
            }
            adjacency[key] = []
        }
        for key in removedKeys {
            adjacency.removeValue(forKey: key)
            elements.removeValue(forKey: key)
        }

        // Mutate: updates keep their position, removals drop, adds append.
        for shape in delta.updatedShapes { topShapes[shapeIndexByID[shape.id]!] = shape }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            topShapes.removeAll { removed.contains($0.id) }
        }
        topShapes.append(contentsOf: delta.addedShapes)
        if delta.removedShapeIDs.isEmpty {
            for (offset, shape) in delta.addedShapes.enumerated() {
                shapeIndexByID[shape.id] = topShapes.count - delta.addedShapes.count + offset
            }
        } else {
            rebuildShapeIndex()
        }
        for via in delta.updatedVias { topVias[viaIndexByID[via.id]!] = via }
        if !delta.removedViaIDs.isEmpty {
            let removed = Set(delta.removedViaIDs)
            topVias.removeAll { removed.contains($0.id) }
        }
        topVias.append(contentsOf: delta.addedVias)
        if delta.removedViaIDs.isEmpty {
            for (offset, via) in delta.addedVias.enumerated() {
                viaIndexByID[via.id] = topVias.count - delta.addedVias.count + offset
            }
        } else {
            rebuildViaIndex()
        }

        for shape in delta.updatedShapes + delta.addedShapes {
            elements[.shape(.top(shape.id))] = LayoutConnectivityExtractor.makeShapeElement(
                shape, key: .shape(.top(shape.id))
            )
        }
        for via in delta.updatedVias + delta.addedVias {
            elements[.via(.top(via.id))] = LayoutConnectivityExtractor.makeViaElement(
                via, key: .via(.top(via.id)), tech: tech, service: service
            )
        }
        for key in addedKeys { adjacency[key] = [] }

        // Re-test geometry contact for the surviving edited elements only,
        // against the maintained spatial index.
        let survivingEditedKeys = updatedKeys + addedKeys
        for key in survivingEditedKeys {
            guard let element = elements[key] else {
                assertionFailure("surviving edited element always has a table entry")
                continue
            }
            contactIndex.insert(key, boundingBox: element.boundingBox)
        }
        for key in survivingEditedKeys {
            guard let element = elements[key] else { continue }
            let contacts = LayoutConnectivityExtractor.contacts(
                of: element,
                candidates: contactIndex.candidates(near: element.boundingBox),
                elements: elements,
                service: service
            )
            for neighbour in contacts {
                adjacency[key]!.insert(neighbour)
                adjacency[neighbour]!.insert(key)
            }
        }

        // Components an edited element touches after the edit dissolve too:
        // the new contact may fuse them with other affected geometry.
        for key in survivingEditedKeys {
            for neighbour in adjacency[key]! {
                if let componentID = componentIDByKey[neighbour] {
                    dissolvedComponentIDs.insert(componentID)
                }
            }
        }

        // Affected key set: all members of dissolved components that still
        // exist, plus the surviving edited elements themselves.
        var affectedKeys: Set<ConnectivityElementKey> = Set(survivingEditedKeys)
        for componentID in dissolvedComponentIDs {
            guard let members = membersByComponentID[componentID] else {
                assertionFailure("dissolved component must exist in the partition")
                continue
            }
            for member in members {
                componentIDByKey.removeValue(forKey: member)
                if elements[member] != nil { affectedKeys.insert(member) }
            }
            membersByComponentID.removeValue(forKey: componentID)
            netByComponentID.removeValue(forKey: componentID)
        }

        let rebuiltComponentCount = repartition(affectedKeys: affectedKeys)

        let analysis = LayoutConnectivityExtractor.analysis(
            nets: netsInCanonicalOrder(),
            elements: elements
        )
        return LiveConnectivityUpdate(
            analysis: analysis,
            recomputedElementCount: affectedKeys.count,
            recomputedComponentCount: rebuiltComponentCount,
            duration: clock.now - start
        )
    }

    /// Full re-extraction from a fresh document — the explicit path for
    /// structural changes a delta cannot express (pins, instances, child
    /// cells). The technology database stays fixed for the session.
    public func rebuild(document: LayoutDocument, cellID: UUID? = nil) throws -> ConnectivityAnalysis {
        try configure(document: document, cellID: cellID)
        return currentAnalysis
    }

    // MARK: - Setup

    private func configure(document: LayoutDocument, cellID: UUID?) throws {
        guard let targetCell = service.resolveCell(document: document, cellID: cellID) else {
            throw LiveConnectivitySessionError.targetCellNotFound
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

        // Flatten appends the target cell's own elements before recursing
        // into instances, so a count split separates editable from constant.
        topShapes = Array(shapes.prefix(targetCell.shapes.count))
        childShapes = Array(shapes.dropFirst(targetCell.shapes.count))
        topVias = Array(vias.prefix(targetCell.vias.count))
        childVias = Array(vias.dropFirst(targetCell.vias.count))
        childShapeIDs = Set(childShapes.map(\.id))
        childViaIDs = Set(childVias.map(\.id))

        // Key-based component bookkeeping needs editable IDs distinct from
        // child contributions; duplicates among multi-instanced children
        // are fine because child occurrences key by position.
        for shape in topShapes where childShapeIDs.contains(shape.id) {
            throw LiveConnectivitySessionError.hierarchyIdentifierCollision(shape.id)
        }
        for via in topVias where childViaIDs.contains(via.id) {
            throw LiveConnectivitySessionError.hierarchyIdentifierCollision(via.id)
        }

        elements = LayoutConnectivityExtractor.makeElements(
            topShapes: topShapes,
            childShapes: childShapes,
            topVias: topVias,
            childVias: childVias,
            tech: tech,
            service: service
        )
        adjacency = LayoutConnectivityExtractor.contactAdjacency(elements: elements, service: service)

        // Cell size is chosen once per generation from the initial design;
        // pruning quality may drift as edits accumulate, correctness never
        // does, and rebuild() re-derives it.
        contactIndex = ConnectivityContactIndex(
            cellSize: ShapeGridIndex.defaultCellSize(for: elements.values.map(\.boundingBox))
        )
        for element in elements.values {
            contactIndex.insert(element.key, boundingBox: element.boundingBox)
        }

        membersByComponentID = [:]
        componentIDByKey = [:]
        netByComponentID = [:]
        nextComponentID = 0
        for members in LayoutConnectivityExtractor.components(adjacency: adjacency, elements: elements) {
            install(componentMembers: members)
        }
        rebuildShapeIndex()
        rebuildViaIndex()
    }

    private func rebuildShapeIndex() {
        shapeIndexByID = Dictionary(
            uniqueKeysWithValues: topShapes.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    private func rebuildViaIndex() {
        viaIndexByID = Dictionary(
            uniqueKeysWithValues: topVias.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    // MARK: - Partition maintenance

    /// Re-derives connected components for the affected key set via a
    /// local union-find. The affected set is closed under adjacency by
    /// construction, so this reproduces the global partition.
    private func repartition(affectedKeys: Set<ConnectivityElementKey>) -> Int {
        guard !affectedKeys.isEmpty else { return 0 }
        let localKeys = affectedKeys.sorted()
        var localIndexByKey: [ConnectivityElementKey: Int] = [:]
        localIndexByKey.reserveCapacity(localKeys.count)
        for (index, key) in localKeys.enumerated() { localIndexByKey[key] = index }

        var unionFind = LayoutUnionFind(count: localKeys.count)
        for (index, key) in localKeys.enumerated() {
            guard let neighbours = adjacency[key] else {
                assertionFailure("affected element must have an adjacency entry")
                continue
            }
            for neighbour in neighbours {
                guard let neighbourIndex = localIndexByKey[neighbour] else {
                    assertionFailure("affected set must be closed under adjacency")
                    continue
                }
                unionFind.union(index, neighbourIndex)
            }
        }

        let locals = unionFind.components().values
            .map { member in member.map { localKeys[$0] }.sorted() }
            .sorted { $0[0] < $1[0] }
        for members in locals {
            install(componentMembers: members)
        }
        return locals.count
    }

    private func install(componentMembers: [ConnectivityElementKey]) {
        let componentID = nextComponentID
        nextComponentID += 1
        membersByComponentID[componentID] = componentMembers
        for key in componentMembers { componentIDByKey[key] = componentID }
        netByComponentID[componentID] = LayoutConnectivityExtractor.net(
            for: componentMembers,
            elements: elements
        )
    }

    /// All cached nets in canonical component order; member lists are kept
    /// sorted, so this matches the batch extractor's output exactly.
    private func netsInCanonicalOrder() -> [ConnectivityNet] {
        netByComponentID.values.sorted { $0.memberKeys[0] < $1.memberKeys[0] }
    }

    // MARK: - Validation

    private func validate(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int],
        viaIndexByID: [UUID: Int]
    ) throws {
        var seenShapeIDs: Set<UUID> = []
        for shape in delta.addedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] == nil else {
                throw LiveConnectivitySessionError.duplicateShapeID(shape.id)
            }
            guard !childShapeIDs.contains(shape.id) else {
                throw LiveConnectivitySessionError.hierarchyIdentifierCollision(shape.id)
            }
        }
        for shape in delta.updatedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] != nil else {
                throw LiveConnectivitySessionError.unknownShapeID(shape.id)
            }
        }
        for id in delta.removedShapeIDs {
            guard seenShapeIDs.insert(id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(id)
            }
            guard shapeIndexByID[id] != nil else {
                throw LiveConnectivitySessionError.unknownShapeID(id)
            }
        }

        var seenViaIDs: Set<UUID> = []
        for via in delta.addedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] == nil else {
                throw LiveConnectivitySessionError.duplicateViaID(via.id)
            }
            guard !childViaIDs.contains(via.id) else {
                throw LiveConnectivitySessionError.hierarchyIdentifierCollision(via.id)
            }
        }
        for via in delta.updatedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] != nil else {
                throw LiveConnectivitySessionError.unknownViaID(via.id)
            }
        }
        for id in delta.removedViaIDs {
            guard seenViaIDs.insert(id).inserted else {
                throw LiveConnectivitySessionError.conflictingDeltaEntry(id)
            }
            guard viaIndexByID[id] != nil else {
                throw LiveConnectivitySessionError.unknownViaID(id)
            }
        }
    }
}
