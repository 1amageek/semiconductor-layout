import Foundation
import LayoutCore
import LayoutTech

/// Incremental DRC over geometry edits to one cell.
///
/// The session keeps the flattened design plus the full violation set
/// bucketed by independent check units, and re-verifies only the units an
/// edit can influence:
///
/// - width / area / spacing: per halo-closed cluster of merged-geometry
///   components within a layer; a layer with non-Manhattan geometry
///   degrades to one whole-layer cluster
/// - rule coverage: per layer
/// - enclosure rules: per layer-pair rule
/// - via enclosure: per via (halo intersection with edited geometry)
/// - shorts: per shape pair involving an edited shape
/// - opens: per net of an edited element
/// - density: per (layer, window) over a per-shape clipped-area cache;
///   every window when the design bounding box moves
///
/// Each unit is a pure function of its own inputs, so recomputing exactly
/// the units whose inputs changed reproduces the full
/// ``LayoutDRCService/run(document:tech:cellID:)`` violation multiset.
/// The antenna check couples every layer through staged connectivity and
/// is deferred: ``apply(_:)`` carries the last antenna result and reports
/// it via ``IncrementalDRCUpdate/staleKinds``; ``commit()`` re-verifies it.
///
/// Structural changes (pins, instances, child cells, technology) are not
/// expressible as deltas; call ``rebuild(document:cellID:)``.
///
/// The session is single-owner mutable state and is not thread-safe.
public final class IncrementalDRCSession {
    private let service = LayoutDRCService()
    private let tech: LayoutTechDatabase

    // Flattened design. The target cell's own elements come first in
    // flatten order and are the editable region; contributions from
    // instantiated child cells are constant across deltas.
    private var topShapes: [LayoutShape] = []
    private var topVias: [LayoutVia] = []
    private var topPins: [LayoutPin] = []
    private var childShapes: [LayoutShape] = []
    private var childVias: [LayoutVia] = []
    private var childPins: [LayoutPin] = []
    private var childShapeIDs: Set<UUID> = []
    private var childViaIDs: Set<UUID> = []

    // Violation buckets, keyed by check unit.
    private var terminalConflictViolations: [LayoutViolation] = []
    private var coverageByLayer: [LayoutLayerID: [LayoutViolation]] = [:]
    private var clusterStateByLayer: [LayoutLayerID: LayerClusterState] = [:]
    private var enclosureByRuleID: [String: [LayoutViolation]] = [:]
    private var viaEnclosureViolations: [LayoutViolation] = []
    private var densityStateByLayer: [LayoutLayerID: LayerDensityState] = [:]
    private var shortViolations: [LayoutViolation] = []
    private var openByNet: [UUID: [LayoutViolation]] = [:]
    private var antennaViolations: [LayoutViolation] = []
    private var antennaIsStale = false

    /// Bounding box of all flattened shapes; density windows depend on it,
    /// so a change forces density re-evaluation on every layer.
    private var overallBoundingBox: LayoutRect?

    public init(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws {
        self.tech = tech
        try configure(document: document, cellID: cellID)
    }

    /// Current violation snapshot. Kinds in ``staleKinds`` are carried
    /// from the last full evaluation, everything else is exact.
    public var currentResult: LayoutDRCResult {
        assembleResult()
    }

    /// Kinds whose violations in ``currentResult`` have not been
    /// re-verified since the last edit; ``commit()`` clears this.
    public var staleKinds: Set<LayoutViolationKind> {
        antennaIsStale ? [.antenna] : []
    }

    /// Applies a geometry delta and re-verifies every check unit the edit
    /// can influence. The returned snapshot is exact except for the kinds
    /// listed in its `staleKinds`.
    public func apply(_ delta: LayoutEditDelta) throws -> IncrementalDRCUpdate {
        let clock = ContinuousClock()
        let start = clock.now

        let shapeIndexByID = Dictionary(
            uniqueKeysWithValues: topShapes.enumerated().map { ($0.element.id, $0.offset) }
        )
        let viaIndexByID = Dictionary(
            uniqueKeysWithValues: topVias.enumerated().map { ($0.element.id, $0.offset) }
        )
        try validate(delta, shapeIndexByID: shapeIndexByID, viaIndexByID: viaIndexByID)

        // Dirty analysis against the pre-edit state.
        var dirtyLayers: Set<LayoutLayerID> = []
        var affectedNets: Set<UUID> = []
        var editedShapeIDs: Set<UUID> = []
        var affectedViaIDs: Set<UUID> = []
        var dirtyRectsByLayer: [LayoutLayerID: [LayoutRect]] = [:]
        var editedKeysByLayer: [LayoutLayerID: Set<FlatShapeKey>] = [:]
        var idListChangedLayers: Set<LayoutLayerID> = []

        func markShape(_ shape: LayoutShape) {
            dirtyLayers.insert(shape.layer)
            editedShapeIDs.insert(shape.id)
            if let netID = shape.netID { affectedNets.insert(netID) }
            dirtyRectsByLayer[shape.layer, default: []]
                .append(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
            editedKeysByLayer[shape.layer, default: []].insert(.top(shape.id))
        }

        for shape in delta.addedShapes {
            markShape(shape)
            idListChangedLayers.insert(shape.layer)
        }
        for shape in delta.updatedShapes {
            let old = topShapes[shapeIndexByID[shape.id]!]
            markShape(old)
            markShape(shape)
            if old.layer != shape.layer {
                idListChangedLayers.insert(old.layer)
                idListChangedLayers.insert(shape.layer)
            }
        }
        for id in delta.removedShapeIDs {
            let old = topShapes[shapeIndexByID[id]!]
            markShape(old)
            idListChangedLayers.insert(old.layer)
        }

        for via in delta.addedVias {
            affectedViaIDs.insert(via.id)
            if let netID = via.netID { affectedNets.insert(netID) }
        }
        for via in delta.updatedVias {
            let old = topVias[viaIndexByID[via.id]!]
            affectedViaIDs.insert(via.id)
            if let netID = old.netID { affectedNets.insert(netID) }
            if let netID = via.netID { affectedNets.insert(netID) }
        }
        for id in delta.removedViaIDs {
            let old = topVias[viaIndexByID[id]!]
            affectedViaIDs.insert(id)
            if let netID = old.netID { affectedNets.insert(netID) }
        }

        // Mutate: updates keep their position, removals drop, adds append.
        for shape in delta.updatedShapes { topShapes[shapeIndexByID[shape.id]!] = shape }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            topShapes.removeAll { removed.contains($0.id) }
        }
        topShapes.append(contentsOf: delta.addedShapes)
        for via in delta.updatedVias { topVias[viaIndexByID[via.id]!] = via }
        if !delta.removedViaIDs.isEmpty {
            let removed = Set(delta.removedViaIDs)
            topVias.removeAll { removed.contains($0.id) }
        }
        topVias.append(contentsOf: delta.addedVias)

        let shapes = topShapes + childShapes
        let vias = topVias + childVias
        let pairsByLayer = Dictionary(grouping: flattenedPairs(), by: { $0.shape.layer })

        // A via's enclosure verdict depends only on geometry inside its
        // enclosure halo (plus dbu rounding slack), so any via whose halo
        // misses every edited bounding box is untouched.
        let roundingSlack = 1.0 / tech.units.dbuPerMicron
        for via in vias where !affectedViaIDs.contains(via.id) {
            guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            let margin = max(def.enclosure.top, def.enclosure.bottom) + roundingSlack
            let halo = service.viaCutRect(for: via, tech: tech).expanded(by: margin, margin)
            for layer in [def.topLayer, def.bottomLayer] {
                guard let rects = dirtyRectsByLayer[layer] else { continue }
                if rects.contains(where: { $0.intersects(halo) }) {
                    affectedViaIDs.insert(via.id)
                    break
                }
            }
        }

        // Per-layer geometric checks: coverage per layer, width/area and
        // spacing per affected cluster.
        for layer in dirtyLayers {
            let layerPairs = pairsByLayer[layer] ?? []
            setBucket(
                &coverageByLayer, layer,
                service.checkRuleCoverage(shapes: layerPairs.map(\.shape), tech: tech)
            )
            updateLayerClusters(
                layer: layer,
                layerPairs: layerPairs,
                editedKeys: editedKeysByLayer[layer] ?? [],
                dirtyRects: dirtyRectsByLayer[layer] ?? []
            )
        }

        // Layer-pair enclosure rules touching a dirty layer.
        let affectedRules = tech.enclosureRules.filter {
            dirtyLayers.contains($0.outerLayer) || dirtyLayers.contains($0.innerLayer)
        }
        for (ruleID, rules) in Dictionary(grouping: affectedRules, by: service.enclosureRuleID) {
            let fresh = service.checkEnclosureRules(shapes: shapes, tech: tech, rules: rules)
            enclosureByRuleID[ruleID] = fresh.isEmpty ? nil : fresh
        }

        // Density windows derive from the overall bounding box: if it
        // moved, every layer's windows moved.
        let newOverall = service.overallBoundingBox(shapes: shapes)
        if newOverall != overallBoundingBox {
            overallBoundingBox = newOverall
            densityStateByLayer = [:]
            if let overall = newOverall {
                for (layer, layerPairs) in pairsByLayer {
                    rebuildLayerDensity(layer: layer, layerPairs: layerPairs, overall: overall)
                }
            }
        } else if let overall = newOverall {
            for layer in dirtyLayers {
                updateLayerDensity(
                    layer: layer,
                    layerPairs: pairsByLayer[layer] ?? [],
                    editedKeys: editedKeysByLayer[layer] ?? [],
                    dirtyRects: dirtyRectsByLayer[layer] ?? [],
                    idListChanged: idListChangedLayers.contains(layer),
                    overall: overall
                )
            }
        }

        // Shorts: a pair verdict depends only on its two shapes.
        shortViolations.removeAll { !Set($0.shapeIDs).isDisjoint(with: editedShapeIDs) }
        shortViolations.append(contentsOf: recomputeShorts(shapes: shapes, editedShapeIDs: editedShapeIDs))

        // Opens: each net's connectivity depends only on its own elements.
        for netID in affectedNets { openByNet[netID] = nil }
        if !affectedNets.isEmpty {
            let netShapes = shapes.filter { $0.netID.map(affectedNets.contains) ?? false }
            let netVias = vias.filter { $0.netID.map(affectedNets.contains) ?? false }
            for violation in service.checkOpens(shapes: netShapes, vias: netVias, tech: tech) {
                guard let netID = violation.netIDs.first else {
                    assertionFailure("open violations always carry their net")
                    continue
                }
                openByNet[netID, default: []].append(violation)
            }
        }

        // Via enclosure for edited vias and vias whose halo was touched.
        viaEnclosureViolations.removeAll {
            $0.viaIDs.first.map(affectedViaIDs.contains) ?? false
        }
        let recomputeVias = vias.filter { affectedViaIDs.contains($0.id) }
        if !recomputeVias.isEmpty {
            viaEnclosureViolations.append(
                contentsOf: service.checkViaEnclosure(shapes: shapes, vias: recomputeVias, tech: tech)
            )
        }

        // Antenna couples layers globally; defer to commit instead of
        // recomputing on every live edit. The carried result is reported
        // as stale, never silently merged as fresh. An empty delta leaves
        // the design untouched, so it must not manufacture staleness.
        if !delta.isEmpty && !tech.antennaRules.isEmpty {
            antennaIsStale = true
        }

        return IncrementalDRCUpdate(
            result: assembleResult(),
            staleKinds: staleKinds,
            recomputedLayers: dirtyLayers.sorted(by: Self.layerOrder),
            recomputedViaCount: recomputeVias.count,
            recomputedNetCount: affectedNets.count,
            duration: clock.now - start
        )
    }

    /// Re-verifies the deferred checks and returns the exact full result.
    public func commit() -> LayoutDRCResult {
        if antennaIsStale {
            antennaViolations = service.checkAntenna(
                shapes: topShapes + childShapes,
                vias: topVias + childVias,
                pins: topPins + childPins,
                tech: tech
            )
            antennaIsStale = false
        }
        return assembleResult()
    }

    /// Full re-verification from a fresh document — the explicit path for
    /// structural changes a delta cannot express (pins, instances, child
    /// cells). The technology database stays fixed for the session.
    public func rebuild(document: LayoutDocument, cellID: UUID? = nil) throws -> LayoutDRCResult {
        try configure(document: document, cellID: cellID)
        return assembleResult()
    }

    // MARK: - Setup

    private func configure(document: LayoutDocument, cellID: UUID?) throws {
        guard let targetCell = service.resolveCell(document: document, cellID: cellID) else {
            throw IncrementalDRCSessionError.targetCellNotFound
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
        topPins = Array(pins.prefix(targetCell.pins.count))
        childPins = Array(pins.dropFirst(targetCell.pins.count))
        childShapeIDs = Set(childShapes.map(\.id))
        childViaIDs = Set(childVias.map(\.id))

        // ID-keyed splicing needs editable IDs to be distinct from child
        // contributions; duplicates among multi-instanced children are fine.
        for shape in topShapes where childShapeIDs.contains(shape.id) {
            throw IncrementalDRCSessionError.hierarchyIdentifierCollision(shape.id)
        }
        for via in topVias where childViaIDs.contains(via.id) {
            throw IncrementalDRCSessionError.hierarchyIdentifierCollision(via.id)
        }

        terminalConflictViolations = conflicts.map(service.makeTerminalConflictViolation)
        rebuildAllBuckets()
    }

    private func rebuildAllBuckets() {
        let shapes = topShapes + childShapes
        let vias = topVias + childVias
        let pins = topPins + childPins
        let pairsByLayer = Dictionary(grouping: flattenedPairs(), by: { $0.shape.layer })

        coverageByLayer = [:]
        clusterStateByLayer = [:]
        for (layer, layerPairs) in pairsByLayer {
            setBucket(
                &coverageByLayer, layer,
                service.checkRuleCoverage(shapes: layerPairs.map(\.shape), tech: tech)
            )
            updateLayerClusters(layer: layer, layerPairs: layerPairs, editedKeys: [], dirtyRects: [])
        }

        enclosureByRuleID = [:]
        for (ruleID, rules) in Dictionary(grouping: tech.enclosureRules, by: service.enclosureRuleID) {
            let fresh = service.checkEnclosureRules(shapes: shapes, tech: tech, rules: rules)
            if !fresh.isEmpty { enclosureByRuleID[ruleID] = fresh }
        }

        viaEnclosureViolations = service.checkViaEnclosure(shapes: shapes, vias: vias, tech: tech)

        overallBoundingBox = service.overallBoundingBox(shapes: shapes)
        densityStateByLayer = [:]
        if let overall = overallBoundingBox {
            for (layer, layerPairs) in pairsByLayer {
                rebuildLayerDensity(layer: layer, layerPairs: layerPairs, overall: overall)
            }
        }

        shortViolations = service.checkShorts(shapes: shapes)

        openByNet = [:]
        for violation in service.checkOpens(shapes: shapes, vias: vias, tech: tech) {
            guard let netID = violation.netIDs.first else {
                assertionFailure("open violations always carry their net")
                continue
            }
            openByNet[netID, default: []].append(violation)
        }

        antennaViolations = service.checkAntenna(shapes: shapes, vias: vias, pins: pins, tech: tech)
        antennaIsStale = false
    }

    /// Flattened shape occurrences in document order, each tagged with its
    /// stable identity.
    private func flattenedPairs() -> [(key: FlatShapeKey, shape: LayoutShape)] {
        var pairs: [(key: FlatShapeKey, shape: LayoutShape)] = []
        pairs.reserveCapacity(topShapes.count + childShapes.count)
        for shape in topShapes { pairs.append((.top(shape.id), shape)) }
        for (index, shape) in childShapes.enumerated() { pairs.append((.child(index), shape)) }
        return pairs
    }

    // MARK: - Cluster maintenance

    /// Replaces the layer's affected clusters with a fresh partition of the
    /// shapes near the edit and re-checks exactly those clusters.
    private func updateLayerClusters(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        editedKeys: Set<FlatShapeKey>,
        dirtyRects: [LayoutRect]
    ) {
        guard let rules = tech.ruleSet(for: layer), !layerPairs.isEmpty else {
            clusterStateByLayer[layer] = nil
            return
        }
        let dbu = tech.units.dbuPerMicron
        let halo = service.clusterHalo(for: rules, tech: tech)
        let manhattan = layerPairs.allSatisfy { service.isManhattanShape($0.shape, dbu: dbu) }

        guard manhattan else {
            // Non-Manhattan geometry sidesteps the scanline banding the
            // partition relies on; one whole-layer cluster is exact by
            // definition, just without locality.
            var state = LayerClusterState()
            state.isMonolithic = true
            installClusters(
                [service.wholeLayerCluster(of: layerPairs.map(\.shape), keys: layerPairs.map(\.key))],
                analyzedPairs: layerPairs,
                into: &state
            )
            clusterStateByLayer[layer] = state
            return
        }

        var state = clusterStateByLayer[layer] ?? LayerClusterState()
        if state.isMonolithic || state.clusters.isEmpty {
            state = LayerClusterState()
            installClusters(
                service.shapeClusters(
                    of: layerPairs.map(\.shape), keys: layerPairs.map(\.key), halo: halo, tech: tech
                ),
                analyzedPairs: layerPairs,
                into: &state
            )
            clusterStateByLayer[layer] = state
            return
        }

        // Affected clusters: those owning an edited occurrence plus those
        // whose halo reach touches edited geometry.
        var affected: Set<FlatShapeKey> = []
        for key in editedKeys {
            if let clusterKey = state.clusterOfShape[key] { affected.insert(clusterKey) }
        }
        for (clusterKey, cluster) in state.clusters where !affected.contains(clusterKey) {
            let reach = cluster.boundingBox.expanded(by: halo, halo)
            if dirtyRects.contains(where: { $0.intersects(reach) }) {
                affected.insert(clusterKey)
            }
        }

        // Re-partition the affected membership plus the edited shapes, then
        // pull in any untouched cluster a fresh cluster now reaches; repeat
        // until the boundary is closed. The fixed point restores the global
        // partition restricted to the subset.
        var subsetKeys = editedKeys
        for clusterKey in affected {
            guard let cluster = state.clusters[clusterKey] else { continue }
            subsetKeys.formUnion(cluster.memberKeys)
        }
        var analyzedPairs: [(key: FlatShapeKey, shape: LayoutShape)] = []
        var newClusters: [LayerShapeCluster] = []
        while true {
            analyzedPairs = layerPairs.filter { subsetKeys.contains($0.key) }
            newClusters = analyzedPairs.isEmpty ? [] : service.shapeClusters(
                of: analyzedPairs.map(\.shape),
                keys: analyzedPairs.map(\.key),
                halo: halo,
                tech: tech
            )
            var grew = false
            for cluster in newClusters {
                let reach = cluster.boundingBox.expanded(by: halo, halo)
                for (oldKey, old) in state.clusters
                where !affected.contains(oldKey) && reach.intersects(old.boundingBox) {
                    affected.insert(oldKey)
                    subsetKeys.formUnion(old.memberKeys)
                    grew = true
                }
            }
            if !grew { break }
        }

        for clusterKey in affected {
            guard let old = state.clusters.removeValue(forKey: clusterKey) else { continue }
            for member in old.memberKeys { state.clusterOfShape[member] = nil }
            state.widthAreaByCluster[clusterKey] = nil
            state.spacingByCluster[clusterKey] = nil
        }
        installClusters(newClusters, analyzedPairs: analyzedPairs, into: &state)
        clusterStateByLayer[layer] = state
    }

    /// Registers the clusters and runs the width/area and spacing checks on
    /// each. `analyzedPairs` must be the array the clusters were built from.
    private func installClusters(
        _ clusters: [LayerShapeCluster],
        analyzedPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        into state: inout LayerClusterState
    ) {
        for cluster in clusters {
            state.clusters[cluster.key] = cluster
            for member in cluster.memberKeys { state.clusterOfShape[member] = cluster.key }
            let clusterShapes = cluster.memberIndices.map { analyzedPairs[$0].shape }
            let widthArea = service.checkWidthAndArea(shapes: clusterShapes, tech: tech)
            if !widthArea.isEmpty { state.widthAreaByCluster[cluster.key] = widthArea }
            let spacing = service.checkSpacing(shapes: clusterShapes, tech: tech)
            if !spacing.isEmpty { state.spacingByCluster[cluster.key] = spacing }
        }
    }

    // MARK: - Density maintenance

    /// Rebuilds the layer's window cache and verdicts from scratch.
    private func rebuildLayerDensity(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        overall: LayoutRect
    ) {
        guard let rules = tech.ruleSet(for: layer), !layerPairs.isEmpty else {
            densityStateByLayer[layer] = nil
            return
        }
        let dbu = tech.units.dbuPerMicron
        let slack = 1.0 / dbu
        var state = LayerDensityState()
        state.windows = service.densityWindows(for: overall, rules: rules)
        state.clippedAreaByWindow = Array(repeating: [:], count: state.windows.count)
        for (windowIndex, window) in state.windows.enumerated() {
            for (key, shape) in layerPairs {
                let bbox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                guard bbox.expanded(by: slack, slack).intersects(window) else { continue }
                state.clippedAreaByWindow[windowIndex][key] =
                    service.clippedArea(of: shape.geometry, in: window, dbu: dbu)
            }
            refreshDensityVerdict(
                layer: layer, layerPairs: layerPairs, rules: rules,
                windowIndex: windowIndex, state: &state
            )
        }
        densityStateByLayer[layer] = state
    }

    /// Re-clips the edited shapes against the windows their old or new
    /// geometry touches and re-emits the verdicts of every window whose
    /// area sum or shape-ID payload can have changed.
    private func updateLayerDensity(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        editedKeys: Set<FlatShapeKey>,
        dirtyRects: [LayoutRect],
        idListChanged: Bool,
        overall: LayoutRect
    ) {
        guard let rules = tech.ruleSet(for: layer), !layerPairs.isEmpty else {
            densityStateByLayer[layer] = nil
            return
        }
        guard var state = densityStateByLayer.removeValue(forKey: layer) else {
            rebuildLayerDensity(layer: layer, layerPairs: layerPairs, overall: overall)
            return
        }
        let dbu = tech.units.dbuPerMicron
        let slack = 1.0 / dbu
        var presentEdited: [FlatShapeKey: LayoutShape] = [:]
        for (key, shape) in layerPairs where editedKeys.contains(key) {
            presentEdited[key] = shape
        }
        for (windowIndex, window) in state.windows.enumerated() {
            // A cache entry can only exist or change where a shape's old or
            // new bounding box (plus rounding slack) meets the window.
            let geometryTouched = dirtyRects.contains {
                $0.expanded(by: slack, slack).intersects(window)
            }
            guard geometryTouched || idListChanged else { continue }
            if geometryTouched {
                for key in editedKeys {
                    if let shape = presentEdited[key],
                       LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                           .expanded(by: slack, slack).intersects(window) {
                        state.clippedAreaByWindow[windowIndex][key] =
                            service.clippedArea(of: shape.geometry, in: window, dbu: dbu)
                    } else {
                        state.clippedAreaByWindow[windowIndex].removeValue(forKey: key)
                    }
                }
            }
            refreshDensityVerdict(
                layer: layer, layerPairs: layerPairs, rules: rules,
                windowIndex: windowIndex, state: &state
            )
        }
        densityStateByLayer[layer] = state
    }

    /// Sums the cached clipped areas over the layer's shape list in
    /// document order — bit-identical to the full check's reduction — and
    /// stores the window's verdict.
    private func refreshDensityVerdict(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        rules: LayoutLayerRuleSet,
        windowIndex: Int,
        state: inout LayerDensityState
    ) {
        let cache = state.clippedAreaByWindow[windowIndex]
        let area = layerPairs.reduce(0.0) { $0 + (cache[$1.key] ?? 0.0) }
        state.violationByWindow[windowIndex] = service.densityViolation(
            layerShapes: layerPairs.map(\.shape),
            layer: layer,
            rules: rules,
            window: state.windows[windowIndex],
            area: area
        )
    }

    // MARK: - Delta validation

    private func validate(
        _ delta: LayoutEditDelta,
        shapeIndexByID: [UUID: Int],
        viaIndexByID: [UUID: Int]
    ) throws {
        var seenShapeIDs: Set<UUID> = []
        for shape in delta.addedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] == nil else {
                throw IncrementalDRCSessionError.duplicateShapeID(shape.id)
            }
            guard !childShapeIDs.contains(shape.id) else {
                throw IncrementalDRCSessionError.hierarchyIdentifierCollision(shape.id)
            }
        }
        for shape in delta.updatedShapes {
            guard seenShapeIDs.insert(shape.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(shape.id)
            }
            guard shapeIndexByID[shape.id] != nil else {
                throw IncrementalDRCSessionError.unknownShapeID(shape.id)
            }
        }
        for id in delta.removedShapeIDs {
            guard seenShapeIDs.insert(id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(id)
            }
            guard shapeIndexByID[id] != nil else {
                throw IncrementalDRCSessionError.unknownShapeID(id)
            }
        }

        var seenViaIDs: Set<UUID> = []
        for via in delta.addedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] == nil else {
                throw IncrementalDRCSessionError.duplicateViaID(via.id)
            }
            guard !childViaIDs.contains(via.id) else {
                throw IncrementalDRCSessionError.hierarchyIdentifierCollision(via.id)
            }
        }
        for via in delta.updatedVias {
            guard seenViaIDs.insert(via.id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(via.id)
            }
            guard viaIndexByID[via.id] != nil else {
                throw IncrementalDRCSessionError.unknownViaID(via.id)
            }
        }
        for id in delta.removedViaIDs {
            guard seenViaIDs.insert(id).inserted else {
                throw IncrementalDRCSessionError.conflictingDeltaEntry(id)
            }
            guard viaIndexByID[id] != nil else {
                throw IncrementalDRCSessionError.unknownViaID(id)
            }
        }
    }

    // MARK: - Recompute helpers

    /// Short pairs involving an edited, still-present shape, emitted with
    /// the lower flattened index first so payloads match the full scan.
    private func recomputeShorts(
        shapes: [LayoutShape],
        editedShapeIDs: Set<UUID>
    ) -> [LayoutViolation] {
        guard !editedShapeIDs.isEmpty else { return [] }
        struct PairKey: Hashable {
            let low: Int
            let high: Int
        }
        var seenPairs: Set<PairKey> = []
        var violations: [LayoutViolation] = []
        let editedIndices = shapes.indices.filter { editedShapeIDs.contains(shapes[$0].id) }
        for editedIndex in editedIndices {
            let edited = shapes[editedIndex]
            for partnerIndex in shapes.indices where partnerIndex != editedIndex {
                guard shapes[partnerIndex].layer == edited.layer else { continue }
                let key = PairKey(
                    low: min(editedIndex, partnerIndex),
                    high: max(editedIndex, partnerIndex)
                )
                guard seenPairs.insert(key).inserted else { continue }
                if let violation = service.sameLayerShortViolation(
                    first: shapes[key.low],
                    second: shapes[key.high]
                ) {
                    violations.append(violation)
                }
            }
        }
        return violations
    }

    // MARK: - Assembly

    private func setBucket(
        _ buckets: inout [LayoutLayerID: [LayoutViolation]],
        _ layer: LayoutLayerID,
        _ violations: [LayoutViolation]
    ) {
        buckets[layer] = violations.isEmpty ? nil : violations
    }

    private static func layerOrder(_ a: LayoutLayerID, _ b: LayoutLayerID) -> Bool {
        if a.name != b.name { return a.name < b.name }
        return a.purpose < b.purpose
    }

    private func assembleResult() -> LayoutDRCResult {
        var violations: [LayoutViolation] = []
        violations += terminalConflictViolations
        for layer in coverageByLayer.keys.sorted(by: Self.layerOrder) {
            violations += coverageByLayer[layer] ?? []
        }
        let clusterLayers = clusterStateByLayer.keys.sorted(by: Self.layerOrder)
        for layer in clusterLayers {
            guard let state = clusterStateByLayer[layer] else { continue }
            for clusterKey in state.widthAreaByCluster.keys.sorted() {
                violations += state.widthAreaByCluster[clusterKey] ?? []
            }
        }
        for layer in clusterLayers {
            guard let state = clusterStateByLayer[layer] else { continue }
            for clusterKey in state.spacingByCluster.keys.sorted() {
                violations += state.spacingByCluster[clusterKey] ?? []
            }
        }
        for ruleID in enclosureByRuleID.keys.sorted() {
            violations += enclosureByRuleID[ruleID] ?? []
        }
        violations += viaEnclosureViolations
        for layer in densityStateByLayer.keys.sorted(by: Self.layerOrder) {
            guard let state = densityStateByLayer[layer] else { continue }
            for windowIndex in state.violationByWindow.keys.sorted() {
                violations.append(state.violationByWindow[windowIndex]!)
            }
        }
        violations += shortViolations
        for netID in openByNet.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            violations += openByNet[netID] ?? []
        }
        violations += antennaViolations
        return LayoutDRCResult(violations: violations)
    }
}
