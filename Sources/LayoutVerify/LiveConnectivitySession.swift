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
    /// Flattened pins (structural between rebuilds); net-carrying pins
    /// tag their islands' declared nets in every emitted analysis.
    private var flatPins: [LayoutPin] = []

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

    private struct SessionConfiguration {
        var topShapes: [LayoutShape]
        var topVias: [LayoutVia]
        var childShapes: [LayoutShape]
        var childVias: [LayoutVia]
        var childShapeIDs: Set<UUID>
        var childViaIDs: Set<UUID>
        var flatPins: [LayoutPin]
        var elements: [ConnectivityElementKey: ConnectivityElement]
        var adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>]
        var contactIndex: ConnectivityContactIndex
        var partition: PartitionState
        var shapeIndexByID: [UUID: Int]
        var viaIndexByID: [UUID: Int]
    }

    private struct FlattenedLayout {
        var topShapes: [LayoutShape]
        var topVias: [LayoutVia]
        var childShapes: [LayoutShape]
        var childVias: [LayoutVia]
        var childShapeIDs: Set<UUID>
        var childViaIDs: Set<UUID>
        var flatPins: [LayoutPin]
    }

    private struct PartitionState {
        var membersByComponentID: [Int: [ConnectivityElementKey]] = [:]
        var componentIDByKey: [ConnectivityElementKey: Int] = [:]
        var netByComponentID: [Int: ConnectivityNet] = [:]
        var nextComponentID = 0
    }

    private struct DeltaElementKeys {
        var removedKeys: [ConnectivityElementKey]
        var updatedKeys: [ConnectivityElementKey]
        var addedKeys: [ConnectivityElementKey]

        var preEditKeys: [ConnectivityElementKey] { removedKeys + updatedKeys }
        var survivingEditedKeys: [ConnectivityElementKey] { updatedKeys + addedKeys }
    }

    private struct ShapeUpdate {
        var index: Int
        var shape: LayoutShape
    }

    private struct ViaUpdate {
        var index: Int
        var via: LayoutVia
    }

    private struct ResolvedEditableGeometryEdit {
        var shapeUpdates: [ShapeUpdate]
        var viaUpdates: [ViaUpdate]
    }

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
            nets: LayoutConnectivityExtractor.tagPinNets(
                nets: netsInCanonicalOrder(),
                pins: flatPins,
                elements: elements
            ),
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
        let keys = Self.makeDeltaElementKeys(delta)
        let geometryEdit = try resolveEditableGeometryEdit(delta)
        var dissolvedComponentIDs = componentIDs(containing: keys.preEditKeys)
        let oldContactsByUpdatedKey = contactSnapshot(for: keys.updatedKeys)

        removePreEditGraphEntries(keys.preEditKeys, removedKeys: keys.removedKeys)
        applyEditableGeometry(delta, resolvedEdit: geometryEdit)
        updateElementTable(delta, addedKeys: keys.addedKeys)
        refreshContacts(for: keys.survivingEditedKeys)

        if let update = refreshIfContactsUnchanged(
            keys: keys,
            oldContactsByUpdatedKey: oldContactsByUpdatedKey,
            dissolvedComponentIDs: dissolvedComponentIDs,
            duration: clock.now - start
        ) {
            return update
        }

        dissolvedComponentIDs.formUnion(componentIDs(touchedByPostEditContacts: keys.survivingEditedKeys))
        let affectedKeys = dissolveComponents(
            dissolvedComponentIDs,
            survivingEditedKeys: keys.survivingEditedKeys
        )
        let rebuiltComponentCount = repartition(affectedKeys: affectedKeys)
        return makeUpdate(
            recomputedElementCount: affectedKeys.count,
            recomputedComponentCount: rebuiltComponentCount,
            duration: clock.now - start
        )
    }

    private static func makeDeltaElementKeys(_ delta: LayoutEditDelta) -> DeltaElementKeys {
        DeltaElementKeys(
            removedKeys: delta.removedShapeIDs.map { .shape(.top($0)) } +
                delta.removedViaIDs.map { .via(.top($0)) },
            updatedKeys: delta.updatedShapes.map { .shape(.top($0.id)) } +
                delta.updatedVias.map { .via(.top($0.id)) },
            addedKeys: delta.addedShapes.map { .shape(.top($0.id)) } +
                delta.addedVias.map { .via(.top($0.id)) }
        )
    }

    private func resolveEditableGeometryEdit(_ delta: LayoutEditDelta) throws -> ResolvedEditableGeometryEdit {
        var shapeUpdates: [ShapeUpdate] = []
        for shape in delta.updatedShapes {
            guard let index = shapeIndexByID[shape.id], topShapes.indices.contains(index) else {
                throw LiveConnectivitySessionError.unknownShapeID(shape.id)
            }
            shapeUpdates.append(ShapeUpdate(index: index, shape: shape))
        }
        var viaUpdates: [ViaUpdate] = []
        for via in delta.updatedVias {
            guard let index = viaIndexByID[via.id], topVias.indices.contains(index) else {
                throw LiveConnectivitySessionError.unknownViaID(via.id)
            }
            viaUpdates.append(ViaUpdate(index: index, via: via))
        }
        return ResolvedEditableGeometryEdit(shapeUpdates: shapeUpdates, viaUpdates: viaUpdates)
    }

    private func componentIDs(containing keys: [ConnectivityElementKey]) -> Set<Int> {
        var componentIDs: Set<Int> = []
        for key in keys {
            if let componentID = componentIDByKey[key] {
                componentIDs.insert(componentID)
            }
        }
        return componentIDs
    }

    private func contactSnapshot(
        for keys: [ConnectivityElementKey]
    ) -> [ConnectivityElementKey: Set<ConnectivityElementKey>] {
        var snapshot: [ConnectivityElementKey: Set<ConnectivityElementKey>] = [:]
        for key in keys {
            snapshot[key] = adjacency[key] ?? []
        }
        return snapshot
    }

    private func removePreEditGraphEntries(
        _ keys: [ConnectivityElementKey],
        removedKeys: [ConnectivityElementKey]
    ) {
        for key in keys {
            if let element = elements[key] {
                contactIndex.remove(key, boundingBox: element.boundingBox)
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
    }

    private func applyEditableGeometry(
        _ delta: LayoutEditDelta,
        resolvedEdit: ResolvedEditableGeometryEdit
    ) {
        for update in resolvedEdit.shapeUpdates {
            topShapes[update.index] = update.shape
        }
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

        for update in resolvedEdit.viaUpdates {
            topVias[update.index] = update.via
        }
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
    }

    private func updateElementTable(_ delta: LayoutEditDelta, addedKeys: [ConnectivityElementKey]) {
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
    }

    private func refreshContacts(for keys: [ConnectivityElementKey]) {
        for key in keys {
            guard let element = elements[key] else {
                continue
            }
            contactIndex.insert(key, boundingBox: element.boundingBox)
        }
        for key in keys {
            guard let element = elements[key] else { continue }
            let contacts = LayoutConnectivityExtractor.contacts(
                of: element,
                candidates: contactIndex.candidates(near: element.boundingBox),
                elements: elements,
                service: service
            )
            for neighbour in contacts {
                adjacency[key, default: []].insert(neighbour)
                adjacency[neighbour, default: []].insert(key)
            }
        }
    }

    private func refreshIfContactsUnchanged(
        keys: DeltaElementKeys,
        oldContactsByUpdatedKey: [ConnectivityElementKey: Set<ConnectivityElementKey>],
        dissolvedComponentIDs: Set<Int>,
        duration: Duration
    ) -> LiveConnectivityUpdate? {
        guard keys.removedKeys.isEmpty && keys.addedKeys.isEmpty else { return nil }
        let contactsUnchanged = keys.updatedKeys.allSatisfy {
            (adjacency[$0] ?? []) == (oldContactsByUpdatedKey[$0] ?? [])
        }
        guard contactsUnchanged else { return nil }

        var refreshedElementCount = 0
        for componentID in dissolvedComponentIDs {
            guard let members = membersByComponentID[componentID] else {
                continue
            }
            refreshedElementCount += members.count
            netByComponentID[componentID] = LayoutConnectivityExtractor.net(
                for: members,
                elements: elements
            )
        }
        return makeUpdate(
            recomputedElementCount: refreshedElementCount,
            recomputedComponentCount: 0,
            duration: duration
        )
    }

    private func componentIDs(touchedByPostEditContacts keys: [ConnectivityElementKey]) -> Set<Int> {
        var componentIDs: Set<Int> = []
        for key in keys {
            for neighbour in adjacency[key] ?? [] {
                if let componentID = componentIDByKey[neighbour] {
                    componentIDs.insert(componentID)
                }
            }
        }
        return componentIDs
    }

    private func dissolveComponents(
        _ componentIDs: Set<Int>,
        survivingEditedKeys: [ConnectivityElementKey]
    ) -> Set<ConnectivityElementKey> {
        var affectedKeys: Set<ConnectivityElementKey> = Set(survivingEditedKeys)
        for componentID in componentIDs {
            guard let members = membersByComponentID[componentID] else {
                continue
            }
            for member in members {
                componentIDByKey.removeValue(forKey: member)
                if elements[member] != nil { affectedKeys.insert(member) }
            }
            membersByComponentID.removeValue(forKey: componentID)
            netByComponentID.removeValue(forKey: componentID)
        }
        return affectedKeys
    }

    private func makeUpdate(
        recomputedElementCount: Int,
        recomputedComponentCount: Int,
        duration: Duration
    ) -> LiveConnectivityUpdate {
        LiveConnectivityUpdate(
            analysis: currentAnalysis,
            recomputedElementCount: recomputedElementCount,
            recomputedComponentCount: recomputedComponentCount,
            duration: duration
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
        let configuration = try makeConfiguration(document: document, cellID: cellID)
        install(configuration)
    }

    private func makeConfiguration(document: LayoutDocument, cellID: UUID?) throws -> SessionConfiguration {
        let flattened = try makeFlattenedLayout(document: document, cellID: cellID)
        try Self.validateConfigurationIDs(flattened)
        let elements = LayoutConnectivityExtractor.makeElements(
            topShapes: flattened.topShapes,
            childShapes: flattened.childShapes,
            topVias: flattened.topVias,
            childVias: flattened.childVias,
            tech: tech,
            service: service
        )
        let adjacency = LayoutConnectivityExtractor.contactAdjacency(elements: elements, service: service)
        return SessionConfiguration(
            topShapes: flattened.topShapes,
            topVias: flattened.topVias,
            childShapes: flattened.childShapes,
            childVias: flattened.childVias,
            childShapeIDs: flattened.childShapeIDs,
            childViaIDs: flattened.childViaIDs,
            flatPins: flattened.flatPins,
            elements: elements,
            adjacency: adjacency,
            contactIndex: Self.makeContactIndex(elements: elements),
            partition: Self.makePartitionState(adjacency: adjacency, elements: elements),
            shapeIndexByID: Self.makeShapeIndex(flattened.topShapes),
            viaIndexByID: Self.makeViaIndex(flattened.topVias)
        )
    }

    private func makeFlattenedLayout(document: LayoutDocument, cellID: UUID?) throws -> FlattenedLayout {
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
        let topShapes = Array(shapes.prefix(targetCell.shapes.count))
        let childShapes = Array(shapes.dropFirst(targetCell.shapes.count))
        let topVias = Array(vias.prefix(targetCell.vias.count))
        let childVias = Array(vias.dropFirst(targetCell.vias.count))
        let childShapeIDs = Set(childShapes.map(\.id))
        let childViaIDs = Set(childVias.map(\.id))

        return FlattenedLayout(
            topShapes: topShapes,
            topVias: topVias,
            childShapes: childShapes,
            childVias: childVias,
            childShapeIDs: childShapeIDs,
            childViaIDs: childViaIDs,
            flatPins: pins
        )
    }

    private static func validateConfigurationIDs(_ flattened: FlattenedLayout) throws {
        try validateUniqueTopShapeIDs(flattened.topShapes)
        try validateUniqueTopViaIDs(flattened.topVias)

        // Key-based component bookkeeping needs editable IDs distinct from
        // child contributions; duplicates among multi-instanced children
        // are fine because child occurrences key by position.
        for shape in flattened.topShapes where flattened.childShapeIDs.contains(shape.id) {
            throw LiveConnectivitySessionError.hierarchyIdentifierCollision(shape.id)
        }
        for via in flattened.topVias where flattened.childViaIDs.contains(via.id) {
            throw LiveConnectivitySessionError.hierarchyIdentifierCollision(via.id)
        }
    }

    private static func makeContactIndex(
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> ConnectivityContactIndex {
        // Cell size is chosen once per generation from the initial design;
        // pruning quality may drift as edits accumulate, correctness never
        // does, and rebuild() re-derives it.
        var contactIndex = ConnectivityContactIndex(
            cellSize: ShapeGridIndex.defaultCellSize(for: elements.values.map(\.boundingBox))
        )
        for element in elements.values {
            contactIndex.insert(element.key, boundingBox: element.boundingBox)
        }
        return contactIndex
    }

    private func install(_ configuration: SessionConfiguration) {
        topShapes = configuration.topShapes
        topVias = configuration.topVias
        childShapes = configuration.childShapes
        childVias = configuration.childVias
        childShapeIDs = configuration.childShapeIDs
        childViaIDs = configuration.childViaIDs
        flatPins = configuration.flatPins
        elements = configuration.elements
        adjacency = configuration.adjacency
        contactIndex = configuration.contactIndex
        membersByComponentID = configuration.partition.membersByComponentID
        componentIDByKey = configuration.partition.componentIDByKey
        netByComponentID = configuration.partition.netByComponentID
        nextComponentID = configuration.partition.nextComponentID
        shapeIndexByID = configuration.shapeIndexByID
        viaIndexByID = configuration.viaIndexByID
    }

    private func rebuildShapeIndex() {
        shapeIndexByID = Self.makeShapeIndex(topShapes)
    }

    private func rebuildViaIndex() {
        viaIndexByID = Self.makeViaIndex(topVias)
    }

    private static func makeShapeIndex(_ shapes: [LayoutShape]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: shapes.enumerated().map { ($0.element.id, $0.offset) })
    }

    private static func makeViaIndex(_ vias: [LayoutVia]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: vias.enumerated().map { ($0.element.id, $0.offset) })
    }

    private static func validateUniqueTopShapeIDs(_ shapes: [LayoutShape]) throws {
        var seen: Set<UUID> = []
        for shape in shapes {
            guard seen.insert(shape.id).inserted else {
                throw LiveConnectivitySessionError.duplicateShapeID(shape.id)
            }
        }
    }

    private static func validateUniqueTopViaIDs(_ vias: [LayoutVia]) throws {
        var seen: Set<UUID> = []
        for via in vias {
            guard seen.insert(via.id).inserted else {
                throw LiveConnectivitySessionError.duplicateViaID(via.id)
            }
        }
    }

    private static func makePartitionState(
        adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>],
        elements: [ConnectivityElementKey: ConnectivityElement]
    ) -> PartitionState {
        var state = PartitionState()
        for members in LayoutConnectivityExtractor.components(adjacency: adjacency, elements: elements) {
            let componentID = state.nextComponentID
            state.nextComponentID += 1
            state.membersByComponentID[componentID] = members
            for key in members { state.componentIDByKey[key] = componentID }
            state.netByComponentID[componentID] = LayoutConnectivityExtractor.net(
                for: members,
                elements: elements
            )
        }
        return state
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
                continue
            }
            for neighbour in neighbours {
                guard let neighbourIndex = localIndexByKey[neighbour] else {
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
        try validateShapeDelta(delta, shapeIndexByID: shapeIndexByID)
        try validateViaDelta(delta, viaIndexByID: viaIndexByID)
    }

    private func validateShapeDelta(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int]
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
    }

    private func validateViaDelta(
        _ delta: LayoutEditDelta,
        viaIndexByID: [UUID: Int]
    ) throws {
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
