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

    // Editable element positions, maintained across deltas so apply()
    // does not rebuild ID dictionaries on every edit. Updates keep
    // positions, adds append, and removals rebuild the shifted index.
    private var shapeIndexByID: [UUID: Int] = [:]
    private var viaIndexByID: [UUID: Int] = [:]

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

    // Current flattened shape occurrences, fully incremental: the shape
    // table, per-layer key sets, per-layer spatial grids, and the per-layer
    // non-Manhattan census are all maintained per delta so apply() never
    // rescans the whole design. Per-layer pair ARRAYS (flatten order) are
    // materialized on demand only for the rare paths that need them.
    private var shapeByKey: [FlatShapeKey: LayoutShape] = [:]
    private var shapeKeysByLayer: [LayoutLayerID: Set<FlatShapeKey>] = [:]
    private var shapeGridByLayer: [LayoutLayerID: MutableFlatShapeGridIndex] = [:]
    private var shapeKeysByNet: [UUID: Set<FlatShapeKey>] = [:]
    private var nonManhattanKeys: Set<FlatShapeKey> = []
    private var nonManhattanCountByLayer: [LayoutLayerID: Int] = [:]
    private var viaByKey: [FlatViaKey: LayoutVia] = [:]
    private var viaKeysByID: [UUID: Set<FlatViaKey>] = [:]
    private var viaKeysByNet: [UUID: Set<FlatViaKey>] = [:]
    private var viaHaloGridByLayer: [LayoutLayerID: MutableFlatViaGridIndex] = [:]

    /// Whether any layer rule set actually constrains density. When false,
    /// density windows can never produce a violation, so the per-apply
    /// overall-bounding-box scan and window bookkeeping are skipped — the
    /// verdict is identical either way.
    private var densityIsTracked = false

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
        for shape in delta.updatedShapes {
            let old = topShapes[shapeIndexByID[shape.id]!]
            removeShapeFromGrid(key: .top(shape.id), shape: old)
        }
        for id in delta.removedShapeIDs {
            let old = topShapes[shapeIndexByID[id]!]
            removeShapeFromGrid(key: .top(id), shape: old)
        }
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
        for shape in delta.updatedShapes + delta.addedShapes {
            insertShapeIntoGrid(key: .top(shape.id), shape: shape)
        }
        for via in delta.updatedVias {
            let old = topVias[viaIndexByID[via.id]!]
            removeViaFromNetIndex(key: .top(via.id), via: old)
        }
        for id in delta.removedViaIDs {
            let old = topVias[viaIndexByID[id]!]
            removeViaFromNetIndex(key: .top(id), via: old)
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
        for via in delta.updatedVias + delta.addedVias {
            insertViaIntoNetIndex(key: .top(via.id), via: via)
        }

        // A via's enclosure verdict depends only on geometry inside its
        // layer-specific enclosure halo (plus dbu rounding slack), so a
        // per-layer halo grid finds only vias whose verdict can change.
        // Affected UUIDs drive violation removal; occurrence KEYS drive the
        // recompute, expanded through viaKeysByID because multi-instanced
        // child vias share one UUID across distinct occurrences.
        var affectedViaKeys: Set<FlatViaKey> = []
        for id in affectedViaIDs {
            affectedViaKeys.formUnion(viaKeysByID[id] ?? [])
        }
        for layer in dirtyLayers {
            guard let grid = viaHaloGridByLayer[layer],
                  let rects = dirtyRectsByLayer[layer] else { continue }
            for rect in rects {
                for key in grid.neighbours(of: rect) {
                    guard let via = viaByKey[key],
                          !affectedViaIDs.contains(via.id),
                          let halo = viaHalo(for: via, on: layer),
                          halo.intersects(rect) else {
                        continue
                    }
                    affectedViaIDs.insert(via.id)
                    affectedViaKeys.formUnion(viaKeysByID[via.id] ?? [])
                }
            }
        }

        // Per-layer geometric checks: coverage per layer, width/area and
        // spacing per affected cluster. A layer WITH a rule set can never
        // produce coverage violations, so the per-apply O(layerShapes)
        // re-listing is skipped for it; the empty bucket is identical to
        // what the full check would return.
        for layer in dirtyLayers {
            if tech.ruleSet(for: layer) == nil {
                setBucket(
                    &coverageByLayer, layer,
                    service.checkRuleCoverage(
                        shapes: currentLayerPairs(layer: layer).map(\.shape),
                        tech: tech
                    )
                )
            } else {
                setBucket(&coverageByLayer, layer, [])
            }
            updateLayerClusters(
                layer: layer,
                editedKeys: editedKeysByLayer[layer] ?? [],
                dirtyRects: dirtyRectsByLayer[layer] ?? []
            )
        }

        // Layer-pair enclosure rules touching a dirty layer. The check only
        // reads geometry on each rule's outer and inner layers, so passing
        // exactly those layers' shapes (in flatten order) is verdict-equal
        // to passing the whole design.
        let affectedRules = tech.enclosureRules.filter {
            dirtyLayers.contains($0.outerLayer) || dirtyLayers.contains($0.innerLayer)
        }
        for (ruleID, rules) in Dictionary(grouping: affectedRules, by: service.enclosureRuleID) {
            var ruleLayers = Set<LayoutLayerID>()
            for rule in rules {
                ruleLayers.insert(rule.outerLayer)
                ruleLayers.insert(rule.innerLayer)
            }
            let ruleShapes = ruleLayers
                .flatMap { shapeKeysByLayer[$0] ?? [] }
                .sorted { shapeOrder($0) < shapeOrder($1) }
                .compactMap { shapeByKey[$0] }
            let fresh = service.checkEnclosureRules(shapes: ruleShapes, tech: tech, rules: rules)
            enclosureByRuleID[ruleID] = fresh.isEmpty ? nil : fresh
        }

        // Density windows derive from the overall bounding box: if it
        // moved, every layer's windows moved. Skipped entirely when no
        // rule set constrains density — no window can ever fail then.
        if densityIsTracked {
            let newOverall = service.overallBoundingBox(shapes: topShapes + childShapes)
            if newOverall != overallBoundingBox {
                overallBoundingBox = newOverall
                densityStateByLayer = [:]
                if let overall = newOverall {
                    for layer in shapeKeysByLayer.keys where layerDensityIsRestrictive(layer) {
                        rebuildLayerDensity(
                            layer: layer,
                            layerPairs: currentLayerPairs(layer: layer),
                            overall: overall
                        )
                    }
                }
            } else if let overall = newOverall {
                for layer in dirtyLayers where layerDensityIsRestrictive(layer) {
                    updateLayerDensity(
                        layer: layer,
                        layerPairs: currentLayerPairs(layer: layer),
                        editedKeys: editedKeysByLayer[layer] ?? [],
                        dirtyRects: dirtyRectsByLayer[layer] ?? [],
                        idListChanged: idListChangedLayers.contains(layer),
                        overall: overall
                    )
                }
            }
        }

        // Shorts: a pair verdict depends only on its two shapes.
        shortViolations.removeAll { !Set($0.shapeIDs).isDisjoint(with: editedShapeIDs) }
        shortViolations.append(contentsOf: recomputeShorts(editedShapeIDs: editedShapeIDs))

        // Opens: each net's connectivity depends only on its own elements.
        for netID in affectedNets { openByNet[netID] = nil }
        if !affectedNets.isEmpty {
            let netShapes = shapesForNets(affectedNets)
            let netVias = viasForNets(affectedNets)
            for violation in service.checkOpens(shapes: netShapes, vias: netVias, tech: tech) {
                guard let netID = violation.netIDs.first else {
                    assertionFailure("open violations always carry their net")
                    continue
                }
                openByNet[netID, default: []].append(violation)
            }
        }

        // Via enclosure for edited vias and vias whose halo was touched,
        // resolved by occurrence key in flatten order so the emitted
        // violations match the full scan exactly.
        viaEnclosureViolations.removeAll {
            $0.viaIDs.first.map(affectedViaIDs.contains) ?? false
        }
        let recomputeVias = affectedViaKeys
            .sorted { viaOrder($0) < viaOrder($1) }
            .compactMap { viaByKey[$0] }
        if !recomputeVias.isEmpty {
            viaEnclosureViolations.append(
                contentsOf: checkViaEnclosure(vias: recomputeVias)
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
        // Position indexes first: bucket rebuilding orders per-layer pair
        // arrays by flatten position through shapeOrder/viaOrder.
        rebuildShapeIndex()
        rebuildViaIndex()
        rebuildAllBuckets()
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

    private func rebuildAllBuckets() {
        let shapes = topShapes + childShapes
        let vias = topVias + childVias
        let pins = topPins + childPins
        let pairsByLayer = Dictionary(grouping: flattenedPairs(), by: { $0.shape.layer })
        rebuildShapeIndexes(pairsByLayer: pairsByLayer)
        rebuildNetIndexes()
        densityIsTracked = tech.layerRules.contains { densityRuleIsRestrictive($0) }

        coverageByLayer = [:]
        clusterStateByLayer = [:]
        for (layer, layerPairs) in pairsByLayer {
            setBucket(
                &coverageByLayer, layer,
                service.checkRuleCoverage(shapes: layerPairs.map(\.shape), tech: tech)
            )
            updateLayerClusters(layer: layer, editedKeys: [], dirtyRects: [])
        }

        enclosureByRuleID = [:]
        for (ruleID, rules) in Dictionary(grouping: tech.enclosureRules, by: service.enclosureRuleID) {
            let fresh = service.checkEnclosureRules(shapes: shapes, tech: tech, rules: rules)
            if !fresh.isEmpty { enclosureByRuleID[ruleID] = fresh }
        }

        // The session's own per-layer grids already exist, so the per-via
        // candidate path is the same one apply() uses — one grid build
        // instead of two, identical verdicts.
        viaEnclosureViolations = checkViaEnclosure(vias: vias)

        densityStateByLayer = [:]
        if densityIsTracked {
            overallBoundingBox = service.overallBoundingBox(shapes: shapes)
            if let overall = overallBoundingBox {
                for (layer, layerPairs) in pairsByLayer where layerDensityIsRestrictive(layer) {
                    rebuildLayerDensity(layer: layer, layerPairs: layerPairs, overall: overall)
                }
            }
        } else {
            overallBoundingBox = nil
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

    private func rebuildShapeIndexes(
        pairsByLayer: [LayoutLayerID: [(key: FlatShapeKey, shape: LayoutShape)]]
    ) {
        shapeByKey = [:]
        shapeKeysByLayer = [:]
        shapeGridByLayer = [:]
        nonManhattanKeys = []
        nonManhattanCountByLayer = [:]
        let dbu = tech.units.dbuPerMicron
        for (layer, layerPairs) in pairsByLayer {
            var keys = Set<FlatShapeKey>()
            keys.reserveCapacity(layerPairs.count)
            for (key, shape) in layerPairs {
                shapeByKey[key] = shape
                keys.insert(key)
                if !service.isManhattanShape(shape, dbu: dbu) {
                    nonManhattanKeys.insert(key)
                    nonManhattanCountByLayer[layer, default: 0] += 1
                }
            }
            shapeKeysByLayer[layer] = keys
            let boxes = layerPairs.map { LayoutGeometryAnalysis.boundingBox(for: $0.shape.geometry) }
            shapeGridByLayer[layer] = MutableFlatShapeGridIndex(
                boundingBoxes: zip(layerPairs.map(\.key), boxes).map { (key: $0.0, box: $0.1) },
                cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
            )
        }
    }

    /// The layer's flattened pairs in flatten order, materialized on demand
    /// from the incremental key set. Only paths that genuinely need the
    /// whole layer (initial cluster builds, non-Manhattan layers,
    /// unruled-layer coverage, restrictive-density layers, enclosure-rule
    /// layers) pay this O(K log K); the steady-state apply path does not.
    private func currentLayerPairs(layer: LayoutLayerID) -> [(key: FlatShapeKey, shape: LayoutShape)] {
        guard let keys = shapeKeysByLayer[layer] else { return [] }
        return keys
            .sorted { shapeOrder($0) < shapeOrder($1) }
            .compactMap { key in
                guard let shape = shapeByKey[key] else {
                    assertionFailure("layer key set out of sync with the shape table")
                    return nil
                }
                return (key: key, shape: shape)
            }
    }

    private func layerDensityIsRestrictive(_ layer: LayoutLayerID) -> Bool {
        tech.ruleSet(for: layer).map(densityRuleIsRestrictive) ?? false
    }

    private func rebuildNetIndexes() {
        shapeKeysByNet = [:]
        for (key, shape) in shapeByKey {
            if let netID = shape.netID {
                shapeKeysByNet[netID, default: []].insert(key)
            }
        }

        viaByKey = [:]
        viaKeysByID = [:]
        viaKeysByNet = [:]
        viaHaloGridByLayer = [:]
        for via in topVias {
            insertViaIntoNetIndex(key: .top(via.id), via: via)
        }
        for (index, via) in childVias.enumerated() {
            insertViaIntoNetIndex(key: .child(index), via: via)
        }
    }

    private func insertShapeIntoGrid(key: FlatShapeKey, shape: LayoutShape) {
        shapeByKey[key] = shape
        shapeKeysByLayer[shape.layer, default: []].insert(key)
        if !service.isManhattanShape(shape, dbu: tech.units.dbuPerMicron) {
            nonManhattanKeys.insert(key)
            nonManhattanCountByLayer[shape.layer, default: 0] += 1
        }
        if let netID = shape.netID {
            shapeKeysByNet[netID, default: []].insert(key)
        }
        let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
        if shapeGridByLayer[shape.layer] == nil {
            shapeGridByLayer[shape.layer] = MutableFlatShapeGridIndex(
                boundingBoxes: [],
                cellSize: ShapeGridIndex.defaultCellSize(for: [box])
            )
        }
        shapeGridByLayer[shape.layer]?.insert(key: key, box: box)
    }

    private func removeShapeFromGrid(key: FlatShapeKey, shape: LayoutShape) {
        shapeByKey[key] = nil
        shapeKeysByLayer[shape.layer]?.remove(key)
        if shapeKeysByLayer[shape.layer]?.isEmpty == true {
            shapeKeysByLayer[shape.layer] = nil
        }
        if nonManhattanKeys.remove(key) != nil {
            nonManhattanCountByLayer[shape.layer, default: 1] -= 1
            if nonManhattanCountByLayer[shape.layer] == 0 {
                nonManhattanCountByLayer[shape.layer] = nil
            }
        }
        if let netID = shape.netID {
            shapeKeysByNet[netID]?.remove(key)
            if shapeKeysByNet[netID]?.isEmpty == true {
                shapeKeysByNet[netID] = nil
            }
        }
        shapeGridByLayer[shape.layer]?.remove(key: key)
    }

    private func insertViaIntoNetIndex(key: FlatViaKey, via: LayoutVia) {
        viaByKey[key] = via
        viaKeysByID[via.id, default: []].insert(key)
        if let netID = via.netID {
            viaKeysByNet[netID, default: []].insert(key)
        }
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { return }
        for layer in Set([def.topLayer, def.bottomLayer]) {
            guard let halo = viaHalo(for: via, on: layer) else { continue }
            if viaHaloGridByLayer[layer] == nil {
                viaHaloGridByLayer[layer] = MutableFlatViaGridIndex(
                    boundingBoxes: [],
                    cellSize: ShapeGridIndex.defaultCellSize(for: [halo])
                )
            }
            viaHaloGridByLayer[layer]?.insert(key: key, box: halo)
        }
    }

    private func removeViaFromNetIndex(key: FlatViaKey, via: LayoutVia) {
        viaByKey[key] = nil
        viaKeysByID[via.id]?.remove(key)
        if viaKeysByID[via.id]?.isEmpty == true {
            viaKeysByID[via.id] = nil
        }
        if let netID = via.netID {
            viaKeysByNet[netID]?.remove(key)
            if viaKeysByNet[netID]?.isEmpty == true {
                viaKeysByNet[netID] = nil
            }
        }
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { return }
        for layer in Set([def.topLayer, def.bottomLayer]) {
            viaHaloGridByLayer[layer]?.remove(key: key)
        }
    }

    private func viaHalo(for via: LayoutVia, on layer: LayoutLayerID) -> LayoutRect? {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { return nil }
        let enclosure: Double
        if layer == def.topLayer {
            enclosure = def.enclosure.top
        } else if layer == def.bottomLayer {
            enclosure = def.enclosure.bottom
        } else {
            return nil
        }
        let roundingSlack = 1.0 / tech.units.dbuPerMicron
        return service.viaCutRect(for: via, tech: tech)
            .expanded(by: enclosure + roundingSlack, enclosure + roundingSlack)
    }

    private func shapesForNets(_ netIDs: Set<UUID>) -> [LayoutShape] {
        netIDs
            .flatMap { shapeKeysByNet[$0] ?? [] }
            .sorted { shapeOrder($0) < shapeOrder($1) }
            .compactMap { shapeByKey[$0] }
    }

    private func viasForNets(_ netIDs: Set<UUID>) -> [LayoutVia] {
        netIDs
            .flatMap { viaKeysByNet[$0] ?? [] }
            .sorted { viaOrder($0) < viaOrder($1) }
            .compactMap { viaByKey[$0] }
    }

    private func shapeOrder(_ key: FlatShapeKey) -> Int {
        switch key {
        case .top(let id):
            shapeIndexByID[id] ?? Int.max
        case .child(let index):
            topShapes.count + index
        }
    }

    private func viaOrder(_ key: FlatViaKey) -> Int {
        switch key {
        case .top(let id):
            viaIndexByID[id] ?? Int.max
        case .child(let index):
            topVias.count + index
        }
    }

    // MARK: - Cluster maintenance

    /// Replaces the layer's affected clusters with a fresh partition of the
    /// shapes near the edit and re-checks exactly those clusters.
    private func updateLayerClusters(
        layer: LayoutLayerID,
        editedKeys: Set<FlatShapeKey>,
        dirtyRects: [LayoutRect]
    ) {
        guard let rules = tech.ruleSet(for: layer),
              shapeKeysByLayer[layer]?.isEmpty == false else {
            clusterStateByLayer[layer] = nil
            return
        }
        let halo = service.clusterHalo(for: rules, tech: tech)
        // The non-Manhattan census is maintained per shape insert/remove,
        // so this is the same verdict the full allSatisfy scan would give
        // without re-evaluating the predicate across the layer.
        let manhattan = (nonManhattanCountByLayer[layer] ?? 0) == 0

        guard manhattan else {
            // Non-Manhattan geometry sidesteps the scanline banding the
            // partition relies on; one whole-layer cluster is exact by
            // definition, just without locality.
            let layerPairs = currentLayerPairs(layer: layer)
            var state = LayerClusterState()
            state.isMonolithic = true
            installClusters(
                [service.wholeLayerCluster(of: layerPairs.map(\.shape), keys: layerPairs.map(\.key))],
                analyzedPairs: layerPairs,
                into: &state
            )
            rebuildClusterGrid(in: &state)
            clusterStateByLayer[layer] = state
            return
        }

        // Take ownership out of the dictionary: a subscript read would
        // leave a second reference and turn every in-place mutation below
        // into a full copy of the per-cluster dictionaries — at ~83k
        // single-shape clusters that copy IS the apply cost.
        var state = clusterStateByLayer.removeValue(forKey: layer) ?? LayerClusterState()
        if state.isMonolithic || state.clusters.isEmpty {
            let layerPairs = currentLayerPairs(layer: layer)
            state = LayerClusterState()
            installClusters(
                service.shapeClusters(
                    of: layerPairs.map(\.shape), keys: layerPairs.map(\.key), halo: halo, tech: tech
                ),
                analyzedPairs: layerPairs,
                into: &state
            )
            rebuildClusterGrid(in: &state)
            clusterStateByLayer[layer] = state
            return
        }

        // Affected clusters: those owning an edited occurrence plus those
        // whose halo reach touches edited geometry.
        var affected: Set<FlatShapeKey> = []
        for key in editedKeys {
            if let clusterKey = state.clusterOfShape[key] { affected.insert(clusterKey) }
        }
        for rect in dirtyRects {
            for clusterKey in clusterKeys(near: rect, margin: halo, state: state)
            where !affected.contains(clusterKey) {
                affected.insert(clusterKey)
            }
        }

        // Re-partition the affected membership plus the edited shapes, then
        // pull in any untouched cluster a fresh cluster now reaches; repeat
        // until the boundary is closed. The fixed point restores the global
        // partition restricted to the subset. The subset is materialized
        // from the shape table in flatten order; edited keys whose shape
        // was removed by this delta — or moved to ANOTHER layer, leaving
        // the same key pointing at a foreign-layer shape — resolve to
        // nothing here, exactly like the layer-array filter they replace.
        var subsetKeys = editedKeys
        for clusterKey in affected {
            guard let cluster = state.clusters[clusterKey] else { continue }
            subsetKeys.formUnion(cluster.memberKeys)
        }
        var analyzedPairs: [(key: FlatShapeKey, shape: LayoutShape)] = []
        var newClusters: [LayerShapeCluster] = []
        while true {
            analyzedPairs = subsetKeys
                .sorted { shapeOrder($0) < shapeOrder($1) }
                .compactMap { key in
                    guard let shape = shapeByKey[key], shape.layer == layer else { return nil }
                    return (key: key, shape: shape)
                }
            newClusters = analyzedPairs.isEmpty ? [] : service.shapeClusters(
                of: analyzedPairs.map(\.shape),
                keys: analyzedPairs.map(\.key),
                halo: halo,
                tech: tech
            )
            var grew = false
            for cluster in newClusters {
                for oldKey in clusterKeys(near: cluster.boundingBox, margin: halo, state: state)
                where !affected.contains(oldKey) {
                    guard let old = state.clusters[oldKey] else { continue }
                    affected.insert(oldKey)
                    subsetKeys.formUnion(old.memberKeys)
                    grew = true
                }
            }
            if !grew { break }
        }

        for clusterKey in affected {
            guard let old = state.clusters.removeValue(forKey: clusterKey) else { continue }
            state.clusterGrid?.remove(key: clusterKey)
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
            state.clusterGrid?.insert(key: cluster.key, box: cluster.boundingBox)
            for member in cluster.memberKeys { state.clusterOfShape[member] = cluster.key }
            let clusterShapes = cluster.memberIndices.map { analyzedPairs[$0].shape }
            let widthArea = service.checkWidthAndArea(shapes: clusterShapes, tech: tech)
            if !widthArea.isEmpty { state.widthAreaByCluster[cluster.key] = widthArea }
            let spacing = service.checkSpacing(shapes: clusterShapes, tech: tech)
            if !spacing.isEmpty { state.spacingByCluster[cluster.key] = spacing }
        }
    }

    private func rebuildClusterGrid(in state: inout LayerClusterState) {
        let boxes = state.clusters.values.map { (key: $0.key, box: $0.boundingBox) }
        state.clusterGrid = MutableFlatShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes.map(\.box))
        )
    }

    private func clusterKeys(
        near rect: LayoutRect,
        margin: Double,
        state: LayerClusterState
    ) -> [FlatShapeKey] {
        if state.clusters.count >= 512, let grid = state.clusterGrid {
            return grid.neighbours(of: rect, margin: margin)
        }
        return state.clusters.compactMap { key, cluster in
            cluster.boundingBox.expanded(by: margin, margin).intersects(rect) ? key : nil
        }.sorted()
    }

    // MARK: - Via enclosure maintenance

    private func checkViaEnclosure(vias: [LayoutVia]) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let roundingSlack = 1.0 / tech.units.dbuPerMicron
        for via in vias {
            guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            let cutRect = service.viaCutRect(for: via, tech: tech)
            let topHalo = cutRect.expanded(by: def.enclosure.top, def.enclosure.top)
            let bottomHalo = cutRect.expanded(by: def.enclosure.bottom, def.enclosure.bottom)
            let topCandidates = shapeCandidates(layer: def.topLayer, near: topHalo, margin: roundingSlack)
            let bottomCandidates = shapeCandidates(layer: def.bottomLayer, near: bottomHalo, margin: roundingSlack)
            if let violation = service.viaEnclosureViolation(
                for: via,
                topCandidates: topCandidates,
                bottomCandidates: bottomCandidates,
                tech: tech
            ) {
                violations.append(violation)
            }
        }
        return violations
    }

    private func shapeCandidates(
        layer: LayoutLayerID,
        near rect: LayoutRect,
        margin: Double
    ) -> [LayoutShape] {
        guard let grid = shapeGridByLayer[layer] else { return [] }
        let probe = rect.expanded(by: margin, margin)
        return grid.neighbours(of: rect, margin: margin).compactMap { key in
            guard let shape = shapeByKey[key],
                  LayoutGeometryAnalysis.boundingBox(for: shape.geometry).intersects(probe) else {
                return nil
            }
            return shape
        }
    }

    // MARK: - Density maintenance

    /// Rebuilds the layer's window cache and verdicts from scratch.
    private func rebuildLayerDensity(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        overall: LayoutRect
    ) {
        guard let rules = tech.ruleSet(for: layer),
              densityRuleIsRestrictive(rules),
              !layerPairs.isEmpty else {
            densityStateByLayer[layer] = nil
            return
        }
        var state = LayerDensityState()
        state.windows = service.densityWindows(for: overall, rules: rules)
        for windowIndex in state.windows.indices {
            refreshDensityVerdict(
                layer: layer, layerPairs: layerPairs, rules: rules,
                windowIndex: windowIndex, state: &state
            )
        }
        densityStateByLayer[layer] = state
    }

    /// Re-derives the verdicts of every window the edited geometry touches
    /// or whose shape-ID payload can have changed; untouched windows keep
    /// their cached verdicts.
    private func updateLayerDensity(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        editedKeys: Set<FlatShapeKey>,
        dirtyRects: [LayoutRect],
        idListChanged: Bool,
        overall: LayoutRect
    ) {
        guard let rules = tech.ruleSet(for: layer),
              densityRuleIsRestrictive(rules),
              !layerPairs.isEmpty else {
            densityStateByLayer[layer] = nil
            return
        }
        guard var state = densityStateByLayer.removeValue(forKey: layer) else {
            rebuildLayerDensity(layer: layer, layerPairs: layerPairs, overall: overall)
            return
        }
        let slack = 1.0 / tech.units.dbuPerMicron
        for (windowIndex, window) in state.windows.enumerated() {
            // A window's merged area can only change where a shape's old or
            // new bounding box (plus rounding slack) meets the window.
            let geometryTouched = dirtyRects.contains {
                $0.expanded(by: slack, slack).intersects(window)
            }
            guard geometryTouched || idListChanged else { continue }
            refreshDensityVerdict(
                layer: layer, layerPairs: layerPairs, rules: rules,
                windowIndex: windowIndex, state: &state
            )
        }
        densityStateByLayer[layer] = state
    }

    private func densityRuleIsRestrictive(_ rules: LayoutLayerRuleSet) -> Bool {
        rules.minDensity > 0 || rules.maxDensity < 1
    }

    /// Recomputes the window's boolean-merged clipped area — identical to
    /// the full check's computation because both call the same union — and
    /// stores the window's verdict.
    private func refreshDensityVerdict(
        layer: LayoutLayerID,
        layerPairs: [(key: FlatShapeKey, shape: LayoutShape)],
        rules: LayoutLayerRuleSet,
        windowIndex: Int,
        state: inout LayerDensityState
    ) {
        let area = service.mergedClippedArea(
            of: layerPairs.map(\.shape),
            in: state.windows[windowIndex],
            dbu: tech.units.dbuPerMicron
        )
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
    private func recomputeShorts(editedShapeIDs: Set<UUID>) -> [LayoutViolation] {
        guard !editedShapeIDs.isEmpty else { return [] }
        struct PairKey: Hashable {
            let lowOrder: Int
            let highOrder: Int
            let lowKey: FlatShapeKey
            let highKey: FlatShapeKey
        }
        var seenPairs: Set<PairKey> = []
        var pairs: [PairKey] = []
        for shapeID in editedShapeIDs {
            let editedKey = FlatShapeKey.top(shapeID)
            guard let edited = shapeByKey[editedKey],
                  let grid = shapeGridByLayer[edited.layer] else { continue }
            let editedBox = LayoutGeometryAnalysis.boundingBox(for: edited.geometry)
            let editedOrder = shapeOrder(editedKey)
            for partnerKey in grid.neighbours(of: editedBox) where partnerKey != editedKey {
                guard let partner = shapeByKey[partnerKey] else { continue }
                let partnerBox = LayoutGeometryAnalysis.boundingBox(for: partner.geometry)
                guard partnerBox.intersects(editedBox) else { continue }
                let partnerOrder = shapeOrder(partnerKey)
                let pair = editedOrder < partnerOrder ? PairKey(
                    lowOrder: editedOrder,
                    highOrder: partnerOrder,
                    lowKey: editedKey,
                    highKey: partnerKey
                ) : PairKey(
                    lowOrder: partnerOrder,
                    highOrder: editedOrder,
                    lowKey: partnerKey,
                    highKey: editedKey
                )
                guard seenPairs.insert(pair).inserted else { continue }
                pairs.append(pair)
            }
        }
        pairs.sort {
            if $0.lowOrder != $1.lowOrder { return $0.lowOrder < $1.lowOrder }
            return $0.highOrder < $1.highOrder
        }
        var violations: [LayoutViolation] = []
        for pair in pairs {
            guard let first = shapeByKey[pair.lowKey],
                  let second = shapeByKey[pair.highKey],
                  let violation = service.sameLayerShortViolation(first: first, second: second) else {
                continue
            }
            violations.append(violation)
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
