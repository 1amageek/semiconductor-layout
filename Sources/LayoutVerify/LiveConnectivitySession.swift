import Foundation
import LayoutCore
import LayoutTech

/// Incremental exact connectivity for geometry edits to one owning cell.
/// Native decomposition and contact probes cover edited sources only, and
/// only touched components are repartitioned. Complete current hierarchy and
/// snapshot materialization, canonical ordering and handle rebinding are
/// separate bounded costs. Preparation never mutates the published generation.
/// Structural edits require rebuild. This synchronous session has one owner
/// and is not Sendable; its immutable returned analyses may be shared.
public final class LiveConnectivitySession {
    private let tech: LayoutTechDatabase
    private let limits: LayoutConductorCaptureLimits
    private var state: State

    private struct State {
        var document: LayoutDocument
        var cellID: UUID
        var snapshot: LayoutConductorSnapshot
        var analysis: ConnectivityAnalysis
        var elements: [ConnectivityElementKey: ConnectivityElement]
        var adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>]
        var contactIndex: ConnectivityContactIndex
        var membersByComponent: [Int: [ConnectivityElementKey]]
        var componentByKey: [ConnectivityElementKey: Int]
        var nextComponentID: Int
        var pinContacts: [Int: Set<ConnectivityElementKey>]
        var sourceKeys: [ConnectivityElementKey: Set<ConnectivityElementKey>]
        var shapeIndexByID: [UUID: Int]
        var viaIndexByID: [UUID: Int]
    }

    public init(document: LayoutDocument, tech: LayoutTechDatabase, cellID: UUID? = nil,
                limits: LayoutConductorCaptureLimits = .default) throws {
        self.tech = tech
        self.limits = limits
        self.state = try Self.makeState(document: document, tech: tech, cellID: cellID, limits: limits)
    }

    public var currentAnalysis: ConnectivityAnalysis { state.analysis }

    public func rebuild(document: LayoutDocument, cellID: UUID? = nil) throws -> ConnectivityAnalysis {
        let prepared = try Self.makeState(document: document, tech: tech, cellID: cellID, limits: limits)
        state = prepared
        return state.analysis
    }

    public func apply(_ delta: LayoutEditDelta) throws -> LiveConnectivityUpdate {
        let clock = ContinuousClock(), start = clock.now
        try Self.validate(delta, shapeIndexByID: state.shapeIndexByID, viaIndexByID: state.viaIndexByID)
        if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
        if delta.isEmpty {
            return LiveConnectivityUpdate(analysis: state.analysis, recomputedElementCount: 0,
                recomputedComponentCount: 0, duration: clock.now - start,
                storedSpatialEntryCount: state.contactIndex.storedEntryCount)
        }
        let additions = delta.addedShapes.count.addingReportingOverflow(delta.addedVias.count)
        guard !additions.overflow, additions.partialValue <= limits.hierarchy.maximumObjects else {
            throw LayoutHierarchyCaptureError.limitExceeded(.objects)
        }
        // Value copies retain the complete old state while preparation mutates
        // the candidate. Full-generation materialization is a deliberate bounded
        // copy cost, distinct from local geometric contact and partition work.
        var pending = state
        try Self.mirror(delta, into: &pending.document, cellID: state.cellID)
        let extractor = LayoutConnectivityExtractor()
        let hierarchy = try extractor.captureHierarchy(document: pending.document, cellID: state.cellID,
            limits: limits.hierarchy)
        guard let root = hierarchy.occurrences.firstIndex(where: {
            $0.parentIndex == nil && $0.sourceCellID == hierarchy.rootCellID
        }) else { throw LayoutConductorCaptureError.invalidComposition }
        let occurrence = hierarchy.occurrences[root]
        let editedShapeIDs = Set((delta.updatedShapes + delta.addedShapes).map(\.id))
        let editedViaIDs = Set((delta.updatedVias + delta.addedVias).map(\.id))
        var selected: Set<LayoutConductorSnapshot.Source> = []
        for index in occurrence.shapeRange where editedShapeIDs.contains(hierarchy.shapes[index].id) { selected.insert(.shape(index)) }
        for index in occurrence.viaRange where editedViaIDs.contains(hierarchy.vias[index].id) { selected.insert(.via(index)) }
        let replacementPreparation = try extractor.captureNativeConductors(document: pending.document, tech: tech,
            conductiveLayers: state.snapshot.conductiveLayers, cellID: state.cellID, limits: limits,
            hierarchy: hierarchy, selectingSources: selected)
        let replacement = replacementPreparation.snapshot
        let captured = try LayoutConnectivityExtractor.capturedElements(replacement)
        let replacedSources = Set(delta.updatedShapes.map { ConnectivityElementKey.shape(.top($0.id)) }
            + delta.addedShapes.map { .shape(.top($0.id)) }
            + delta.updatedVias.map { .via(.top($0.id)) }
            + delta.addedVias.map { .via(.top($0.id)) })
        let retiredSources = Set(delta.removedShapeIDs.map { ConnectivityElementKey.shape(.top($0)) }
            + delta.updatedShapes.map { .shape(.top($0.id)) }
            + delta.removedViaIDs.map { .via(.top($0)) }
            + delta.updatedVias.map { .via(.top($0.id)) })
        let retired = retiredSources.reduce(into: Set<ConnectivityElementKey>()) {
            $0.formUnion(state.sourceKeys[$1, default: []])
        }
        let remaining = state.elements.count - retired.count
        guard remaining >= 0, captured.keys.count <= limits.maximumFootprints - remaining else {
            throw LayoutConductorCaptureError.limitExceeded(.footprints)
        }
        var spatialVisits = 0
        func countSpatialVisits(_ count: Int) throws {
            let sum = spatialVisits.addingReportingOverflow(count)
            guard !sum.overflow else { throw LayoutConductorCaptureError.limitExceeded(.spatialIndexEntries) }
            spatialVisits = sum.partialValue
        }
        var touchedComponents: Set<Int> = []
        for key in retired {
            if let component = state.componentByKey[key] { touchedComponents.insert(component) }
            guard let element = state.elements[key] else { throw LayoutConductorCaptureError.invalidComposition }
            try countSpatialVisits(pending.contactIndex.remove(key, boundingBox: element.boundingBox))
            for neighbour in pending.adjacency[key, default: []] { pending.adjacency[neighbour]?.remove(key) }
            pending.adjacency.removeValue(forKey: key)
            pending.elements.removeValue(forKey: key)
        }
        for source in retiredSources { pending.sourceKeys.removeValue(forKey: source) }
        // Admit all future entries before any new bounding-box walk. Otherwise
        // many individually legal boxes could exceed the global storage/work
        // ceiling before insertion discovers the aggregate failure.
        var futureEntries = pending.contactIndex.storedEntryCount
        for element in captured.elements.values {
            let cost = try pending.contactIndex.entryCost(near: element.boundingBox)
            guard cost <= limits.maximumContactProbes - futureEntries else {
                throw LayoutConductorCaptureError.limitExceeded(.spatialIndexEntries)
            }
            futureEntries += cost
        }
        for source in pending.pinContacts.keys {
            pending.pinContacts[source]?.subtract(retired)
        }
        for (key, element) in captured.elements {
            pending.elements[key] = element
            pending.adjacency[key] = []
            pending.sourceKeys[key.sourceKey, default: []].insert(key)
        }
        for contact in replacement.contacts {
            let first = captured.keys[contact.firstFootprint], second = captured.keys[contact.secondFootprint]
            pending.adjacency[first, default: []].insert(second)
            pending.adjacency[second, default: []].insert(first)
        }
        var probes = replacementPreparation.probeCount
        func chargeProbe() throws {
            if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
            guard probes < limits.maximumContactProbes else { throw LayoutConductorCaptureError.limitExceeded(.contactProbes) }
            probes += 1
        }
        for key in captured.keys {
            guard let element = pending.elements[key], let first = element.footprintIndex else {
                throw LayoutConductorCaptureError.invalidComposition
            }
            let candidates = try pending.contactIndex.candidates(near: element.boundingBox)
            try countSpatialVisits(candidates.cellVisits)
            for otherKey in candidates.keys where otherKey != key {
                // The index contains preserved pieces only during preparation.
                // New-new contacts already come from the native partial capture.
                guard let other = pending.elements[otherKey], let owner = other.conductorCapture,
                      let second = other.footprintIndex else { throw LayoutConductorCaptureError.invalidComposition }
                try chargeProbe()
                if try replacement.hasElectricalContact(footprintAt: first, with: owner, footprintAt: second) {
                    pending.adjacency[key, default: []].insert(otherKey)
                    pending.adjacency[otherKey, default: []].insert(key)
                    if let component = state.componentByKey[otherKey] { touchedComponents.insert(component) }
                }
            }
            for pinIndex in state.snapshot.pins.indices {
                let pin = state.snapshot.pins[pinIndex]
                let sourcePin = state.snapshot.hierarchy.pins[pin.sourcePinIndex]
                let bounds = LayoutGeometryAnalysis.boundingBox(for: state.snapshot.hierarchy.pinGeometries[pin.sourcePinIndex])
                try chargeProbe()
                guard element.layer == sourcePin.layer, bounds.intersects(element.boundingBox) else { continue }
                if try state.snapshot.hasPinContact(pinAt: pinIndex, with: replacement, footprintAt: first) {
                    pending.pinContacts[pin.sourcePinIndex, default: []].insert(key)
                }
            }
        }
        for element in captured.elements.values {
            try countSpatialVisits(pending.contactIndex.insert(element.key, boundingBox: element.boundingBox))
        }
        var affected = Set(captured.keys)
        for component in touchedComponents {
            guard let members = pending.membersByComponent.removeValue(forKey: component) else {
                throw LayoutConductorCaptureError.invalidComposition
            }
            for key in members {
                pending.componentByKey.removeValue(forKey: key)
                if pending.elements[key] != nil { affected.insert(key) }
            }
        }
        let local = try Self.localComponents(keys: affected, adjacency: pending.adjacency)
        for members in local {
            let id = pending.nextComponentID
            let next = id.addingReportingOverflow(1)
            guard !next.overflow else { throw LayoutConductorCaptureError.invalidComposition }
            pending.nextComponentID = next.partialValue
            pending.membersByComponent[id] = members
            for key in members { pending.componentByKey[key] = id }
        }
        let snapshot = try LayoutConnectivityExtractor.composeConductors(hierarchy: hierarchy,
            template: state.snapshot, replacement: replacement, replacementSources: replacedSources,
            elements: pending.elements, adjacency: pending.adjacency,
            componentMembers: Array(pending.membersByComponent.values), pinContacts: pending.pinContacts, limits: limits)
        let rebound = try LayoutConnectivityExtractor.capturedElements(snapshot)
        pending.snapshot = snapshot
        pending.analysis = try LayoutConnectivityExtractor.analysis(from: snapshot)
        pending.elements = rebound.elements
        guard let cell = pending.document.cell(withID: state.cellID) else { throw LiveConnectivitySessionError.targetCellNotFound }
        pending.shapeIndexByID = Dictionary(uniqueKeysWithValues: cell.shapes.enumerated().map { ($0.element.id, $0.offset) })
        pending.viaIndexByID = Dictionary(uniqueKeysWithValues: cell.vias.enumerated().map { ($0.element.id, $0.offset) })
        if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
        state = pending
        return LiveConnectivityUpdate(analysis: pending.analysis, recomputedElementCount: affected.count,
            recomputedComponentCount: local.count, duration: clock.now - start,
            capturedFootprintCount: captured.keys.count, contactProbeCount: probes,
            materializedFootprintCount: snapshot.footprints.count,
            spatialCellVisitCount: spatialVisits, storedSpatialEntryCount: pending.contactIndex.storedEntryCount)
    }

    private static func makeState(document: LayoutDocument, tech: LayoutTechDatabase, cellID: UUID?,
                                  limits: LayoutConductorCaptureLimits) throws -> State {
        guard let cell = LayoutDRCService().resolveCell(document: document, cellID: cellID) else {
            throw LiveConnectivitySessionError.targetCellNotFound
        }
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: document, tech: tech,
            conductiveLayers: LayoutConnectivityExtractor.productionConductiveLayers(tech, limits: limits),
            cellID: cell.id, limits: limits)
        let captured = try LayoutConnectivityExtractor.capturedElements(snapshot)
        var adjacency = Dictionary(uniqueKeysWithValues: captured.keys.map { ($0, Set<ConnectivityElementKey>()) })
        for contact in snapshot.contacts {
            let first = captured.keys[contact.firstFootprint], second = captured.keys[contact.secondFootprint]
            adjacency[first, default: []].insert(second)
            adjacency[second, default: []].insert(first)
        }
        var index = ConnectivityContactIndex(cellSize: ShapeGridIndex.defaultCellSize(for: captured.elements.values.map(\.boundingBox)),
            maximumEntries: limits.maximumContactProbes)
        for element in captured.elements.values { try index.insert(element.key, boundingBox: element.boundingBox) }
        var members: [Int: [ConnectivityElementKey]] = [:], componentByKey: [ConnectivityElementKey: Int] = [:]
        for (id, component) in snapshot.components.enumerated() {
            let keys = component.footprintIndices.map { captured.keys[$0] }.sorted()
            members[id] = keys
            for key in keys { componentByKey[key] = id }
        }
        var pinContacts: [Int: Set<ConnectivityElementKey>] = [:]
        for pin in snapshot.pins {
            pinContacts[pin.sourcePinIndex] = Set(pin.footprintIndices.map { captured.keys[$0] })
        }
        var sourceKeys: [ConnectivityElementKey: Set<ConnectivityElementKey>] = [:]
        for key in captured.keys { sourceKeys[key.sourceKey, default: []].insert(key) }
        return State(document: document, cellID: cell.id, snapshot: snapshot,
            analysis: try LayoutConnectivityExtractor.analysis(from: snapshot), elements: captured.elements,
            adjacency: adjacency, contactIndex: index, membersByComponent: members, componentByKey: componentByKey,
            nextComponentID: snapshot.components.count, pinContacts: pinContacts, sourceKeys: sourceKeys,
            shapeIndexByID: Dictionary(uniqueKeysWithValues: cell.shapes.enumerated().map { ($0.element.id, $0.offset) }),
            viaIndexByID: Dictionary(uniqueKeysWithValues: cell.vias.enumerated().map { ($0.element.id, $0.offset) }))
    }

    private static func localComponents(keys: Set<ConnectivityElementKey>,
                                        adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>]) throws -> [[ConnectivityElementKey]] {
        let ordered = keys.sorted()
        let indexByKey = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        var union = LayoutUnionFind(count: ordered.count)
        for (index, key) in ordered.enumerated() {
            if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
            for neighbour in adjacency[key, default: []] {
                guard let other = indexByKey[neighbour] else { throw LayoutConductorCaptureError.invalidComposition }
                union.union(index, other)
            }
        }
        return union.components().values.map { $0.map { ordered[$0] }.sorted() }.sorted { $0[0] < $1[0] }
    }

    private static func mirror(_ delta: LayoutEditDelta, into document: inout LayoutDocument, cellID: UUID) throws {
        guard let cellIndex = document.cells.firstIndex(where: { $0.id == cellID }) else {
            throw LiveConnectivitySessionError.targetCellNotFound
        }
        var cell = document.cells[cellIndex]
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else { throw LiveConnectivitySessionError.unknownShapeID(shape.id) }
            cell.shapes[index] = shape
        }
        let removedShapes = Set(delta.removedShapeIDs)
        cell.shapes.removeAll { removedShapes.contains($0.id) }
        cell.shapes.append(contentsOf: delta.addedShapes)
        for via in delta.updatedVias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else { throw LiveConnectivitySessionError.unknownViaID(via.id) }
            cell.vias[index] = via
        }
        let removedVias = Set(delta.removedViaIDs)
        cell.vias.removeAll { removedVias.contains($0.id) }
        cell.vias.append(contentsOf: delta.addedVias)
        document.cells[cellIndex] = cell
    }

    private static func validate(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int],
        viaIndexByID: [UUID: Int]
    ) throws {
        try validateShapeDelta(delta, shapeIndexByID: shapeIndexByID)
        try validateViaDelta(delta, viaIndexByID: viaIndexByID)
    }

    private static func validateShapeDelta(
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

    private static func validateViaDelta(
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
