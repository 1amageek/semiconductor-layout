import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    private struct SessionConfiguration {
        var sourceDocument: LayoutDocument
        var sourceCellID: UUID?
        var topShapes: [LayoutShape]
        var topVias: [LayoutVia]
        var topPins: [LayoutPin]
        var childShapes: [LayoutShape]
        var childVias: [LayoutVia]
        var childPins: [LayoutPin]
        var childShapeIDs: Set<UUID>
        var childViaIDs: Set<UUID>
        var terminalConflictViolations: [LayoutViolation]
        var shapeIndexByID: [UUID: Int]
        var viaIndexByID: [UUID: Int]
    }

    private struct FlattenedLayout {
        var topShapes: [LayoutShape]
        var topVias: [LayoutVia]
        var topPins: [LayoutPin]
        var childShapes: [LayoutShape]
        var childVias: [LayoutVia]
        var childPins: [LayoutPin]
        var childShapeIDs: Set<UUID>
        var childViaIDs: Set<UUID>
        var terminalConflicts: [LayoutDRCService.TerminalConnectivityConflict]
    }

    func configure(document: LayoutDocument, cellID: UUID?) throws {
        let configuration = try makeConfiguration(document: document, cellID: cellID)
        install(configuration)
        rebuildAllBuckets()
    }

    private func makeConfiguration(document: LayoutDocument, cellID: UUID?) throws -> SessionConfiguration {
        let checkedDocument = tech.derivedLayerRules.isEmpty
            ? document
            : LayoutDerivedLayerMaterializer.materialize(document: document, tech: tech)

        let flattened = try makeFlattenedLayout(
            checkedDocument: checkedDocument,
            cellID: cellID
        )
        try Self.validateConfigurationIDs(flattened)

        return SessionConfiguration(
            sourceDocument: document,
            sourceCellID: cellID,
            topShapes: flattened.topShapes,
            topVias: flattened.topVias,
            topPins: flattened.topPins,
            childShapes: flattened.childShapes,
            childVias: flattened.childVias,
            childPins: flattened.childPins,
            childShapeIDs: flattened.childShapeIDs,
            childViaIDs: flattened.childViaIDs,
            terminalConflictViolations: flattened.terminalConflicts.map(service.makeTerminalConflictViolation),
            shapeIndexByID: Self.makeShapeIndex(flattened.topShapes),
            viaIndexByID: Self.makeViaIndex(flattened.topVias)
        )
    }

    private func makeFlattenedLayout(
        checkedDocument: LayoutDocument,
        cellID: UUID?
    ) throws -> FlattenedLayout {
        guard let targetCell = service.resolveCell(document: checkedDocument, cellID: cellID) else {
            throw IncrementalDRCSessionError.targetCellNotFound
        }

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var conflicts: [LayoutDRCService.TerminalConnectivityConflict] = []
        service.flatten(
            cell: targetCell,
            document: checkedDocument,
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
        return FlattenedLayout(
            topShapes: Array(shapes.prefix(targetCell.shapes.count)),
            topVias: Array(vias.prefix(targetCell.vias.count)),
            topPins: Array(pins.prefix(targetCell.pins.count)),
            childShapes: Array(shapes.dropFirst(targetCell.shapes.count)),
            childVias: Array(vias.dropFirst(targetCell.vias.count)),
            childPins: Array(pins.dropFirst(targetCell.pins.count)),
            childShapeIDs: Set(shapes.dropFirst(targetCell.shapes.count).map(\.id)),
            childViaIDs: Set(vias.dropFirst(targetCell.vias.count).map(\.id)),
            terminalConflicts: conflicts
        )
    }

    private static func validateConfigurationIDs(_ flattened: FlattenedLayout) throws {
        try validateUniqueTopShapeIDs(flattened.topShapes)
        try validateUniqueTopViaIDs(flattened.topVias)

        // ID-keyed splicing needs editable IDs to be distinct from child
        // contributions; duplicates among multi-instanced children are fine.
        for shape in flattened.topShapes where flattened.childShapeIDs.contains(shape.id) {
            throw IncrementalDRCSessionError.hierarchyIdentifierCollision(shape.id)
        }
        for via in flattened.topVias where flattened.childViaIDs.contains(via.id) {
            throw IncrementalDRCSessionError.hierarchyIdentifierCollision(via.id)
        }
    }

    private func install(_ configuration: SessionConfiguration) {
        sourceDocument = configuration.sourceDocument
        sourceCellID = configuration.sourceCellID
        topShapes = configuration.topShapes
        topVias = configuration.topVias
        topPins = configuration.topPins
        childShapes = configuration.childShapes
        childVias = configuration.childVias
        childPins = configuration.childPins
        childShapeIDs = configuration.childShapeIDs
        childViaIDs = configuration.childViaIDs
        terminalConflictViolations = configuration.terminalConflictViolations
        shapeIndexByID = configuration.shapeIndexByID
        viaIndexByID = configuration.viaIndexByID
    }

    func applyByFullDerivedLayerRebuild(
        _ delta: LayoutEditDelta,
        clock: ContinuousClock,
        start: ContinuousClock.Instant
    ) throws -> IncrementalDRCUpdate {
        guard !delta.isEmpty else {
            return makeEmptyDerivedLayerUpdate(duration: clock.now - start)
        }

        let updatedDocument = try sourceDocument(applying: delta)
        try configure(document: updatedDocument, cellID: sourceCellID)

        return IncrementalDRCUpdate(
            result: assembleResult(),
            staleKinds: staleKinds,
            recomputedLayers: derivedLayerRebuildLayers(),
            recomputedViaCount: topVias.count + childVias.count,
            recomputedNetCount: currentNetCount(),
            duration: clock.now - start
        )
    }

    private func makeEmptyDerivedLayerUpdate(duration: Duration) -> IncrementalDRCUpdate {
        IncrementalDRCUpdate(
            result: assembleResult(),
            staleKinds: staleKinds,
            recomputedLayers: [],
            recomputedViaCount: 0,
            recomputedNetCount: 0,
            duration: duration
        )
    }

    private func sourceDocument(applying delta: LayoutEditDelta) throws -> LayoutDocument {
        guard var targetCell = service.resolveCell(document: sourceDocument, cellID: sourceCellID) else {
            throw IncrementalDRCSessionError.targetCellNotFound
        }
        let sourceShapeIndex = Self.makeShapeIndex(targetCell.shapes)
        let sourceViaIndex = Self.makeViaIndex(targetCell.vias)
        try validate(delta, shapeIndexByID: sourceShapeIndex, viaIndexByID: sourceViaIndex)

        try applyShapeDelta(delta, to: &targetCell, shapeIndexByID: sourceShapeIndex)
        try applyViaDelta(delta, to: &targetCell, viaIndexByID: sourceViaIndex)

        var updatedDocument = sourceDocument
        updatedDocument.updateCell(targetCell)
        return updatedDocument
    }

    private func applyShapeDelta(
        _ delta: LayoutEditDelta,
        to targetCell: inout LayoutCell,
        shapeIndexByID: [UUID: Int]
    ) throws {
        for shape in delta.updatedShapes {
            guard let index = shapeIndexByID[shape.id], targetCell.shapes.indices.contains(index) else {
                throw IncrementalDRCSessionError.unknownShapeID(shape.id)
            }
            targetCell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            targetCell.shapes.removeAll { removed.contains($0.id) }
        }
        targetCell.shapes.append(contentsOf: delta.addedShapes)
    }

    private func applyViaDelta(
        _ delta: LayoutEditDelta,
        to targetCell: inout LayoutCell,
        viaIndexByID: [UUID: Int]
    ) throws {
        for via in delta.updatedVias {
            guard let index = viaIndexByID[via.id], targetCell.vias.indices.contains(index) else {
                throw IncrementalDRCSessionError.unknownViaID(via.id)
            }
            targetCell.vias[index] = via
        }
        if !delta.removedViaIDs.isEmpty {
            let removed = Set(delta.removedViaIDs)
            targetCell.vias.removeAll { removed.contains($0.id) }
        }
        targetCell.vias.append(contentsOf: delta.addedVias)
    }

    private func derivedLayerRebuildLayers() -> [LayoutLayerID] {
        Set(
            (topShapes + childShapes).map(\.layer)
                + tech.derivedLayerRules.flatMap { [$0.targetLayer] + $0.sourceLayers }
        ).sorted(by: Self.layerOrder)
    }

    private func currentNetCount() -> Int {
        Set((topShapes + childShapes).compactMap(\.netID)
            + (topVias + childVias).compactMap(\.netID)).count
    }

    func rebuildShapeIndex() {
        shapeIndexByID = Self.makeShapeIndex(topShapes)
    }

    func rebuildViaIndex() {
        viaIndexByID = Self.makeViaIndex(topVias)
    }

    private static func makeShapeIndex(_ shapes: [LayoutShape]) -> [UUID: Int] {
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(shapes.count)
        for (index, shape) in shapes.enumerated() {
            indexByID[shape.id] = index
        }
        return indexByID
    }

    private static func makeViaIndex(_ vias: [LayoutVia]) -> [UUID: Int] {
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(vias.count)
        for (index, via) in vias.enumerated() {
            indexByID[via.id] = index
        }
        return indexByID
    }

    private static func validateUniqueTopShapeIDs(_ shapes: [LayoutShape]) throws {
        var seen: Set<UUID> = []
        for shape in shapes {
            guard seen.insert(shape.id).inserted else {
                throw IncrementalDRCSessionError.duplicateShapeID(shape.id)
            }
        }
    }

    private static func validateUniqueTopViaIDs(_ vias: [LayoutVia]) throws {
        var seen: Set<UUID> = []
        for via in vias {
            guard seen.insert(via.id).inserted else {
                throw IncrementalDRCSessionError.duplicateViaID(via.id)
            }
        }
    }

    func rebuildAllBuckets() {
        let shapes = topShapes + childShapes
        let vias = topVias + childVias
        let pins = topPins + childPins
        let pairsByLayer = Dictionary(grouping: flattenedPairs(), by: { $0.shape.layer })
        rebuildShapeIndexes(pairsByLayer: pairsByLayer)
        rebuildNetIndexes()
        densityIsTracked = tech.layerRules.contains { densityRuleIsRestrictive($0) }

        coverageByLayer = [:]
        rectOnlyByLayer = [:]
        angleByLayer = [:]
        clusterStateByLayer = [:]
        for (layer, layerPairs) in pairsByLayer {
            let layerRule = tech.ruleSet(for: layer)
            setBucket(
                &coverageByLayer, layer,
                service.checkRuleCoverage(shapes: layerPairs.map(\.shape), tech: tech)
            )
            if layerRule?.requiresRectangular == true || layerRule?.allowedAngleStepDegrees != nil {
                let layerShapes = layerPairs.map(\.shape)
                if layerRule?.requiresRectangular == true {
                    setBucket(
                        &rectOnlyByLayer, layer,
                        service.checkRectangularGeometry(shapes: layerShapes, tech: tech)
                    )
                }
                if layerRule?.allowedAngleStepDegrees != nil {
                    setBucket(
                        &angleByLayer, layer,
                        service.checkAngleRules(shapes: layerShapes, tech: tech)
                    )
                }
            }
            updateLayerClusters(layer: layer, editedKeys: [], dirtyRects: [])
        }

        enclosureByRuleID = [:]
        for (ruleID, rules) in Dictionary(grouping: tech.enclosureRules, by: service.enclosureRuleID) {
            let fresh = service.checkEnclosureRules(shapes: shapes, tech: tech, rules: rules)
            if !fresh.isEmpty { enclosureByRuleID[ruleID] = fresh }
        }
        spacingByRuleID = [:]
        for (ruleID, rules) in Dictionary(grouping: tech.spacingRules, by: service.spacingRuleID) {
            let fresh = service.checkSpacingRules(shapes: shapes, tech: tech, rules: rules)
            if !fresh.isEmpty { spacingByRuleID[ruleID] = fresh }
        }

        // The session's own per-layer grids already exist, so the per-via
        // candidate path is the same one apply() uses — one grid build
        // instead of two, identical verdicts.
        viaEnclosureViolations = checkViaEnclosure(vias: vias)
        forbiddenLayerViolations = service.checkForbiddenLayers(shapes: shapes, tech: tech)
        minimumCutViolations = service.checkMinimumCuts(shapes: shapes, vias: vias, tech: tech)
        exactOverlapViolations = service.checkExactOverlaps(shapes: shapes, tech: tech)

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
                continue
            }
            openByNet[netID, default: []].append(violation)
        }

        antennaViolations = service.checkAntenna(shapes: shapes, vias: vias, pins: pins, tech: tech)
        antennaIsStale = false
    }

    func flattenedPairs() -> [(key: FlatShapeKey, shape: LayoutShape)] {
        var pairs: [(key: FlatShapeKey, shape: LayoutShape)] = []
        pairs.reserveCapacity(topShapes.count + childShapes.count)
        for shape in topShapes { pairs.append((.top(shape.id), shape)) }
        for (index, shape) in childShapes.enumerated() { pairs.append((.child(index), shape)) }
        return pairs
    }

    func rebuildShapeIndexes(
        pairsByLayer: [LayoutLayerID: [(key: FlatShapeKey, shape: LayoutShape)]]
    ) {
        shapeByKey = [:]
        shapeKeysByLayer = [:]
        shapeGridByLayer = [:]
        nonManhattanKeys = []
        nonManhattanCountByLayer = [:]
        let dbu = tech.units.scale.databaseUnitsPerMicrometer
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

    func currentLayerPairs(layer: LayoutLayerID) -> [(key: FlatShapeKey, shape: LayoutShape)] {
        guard let keys = shapeKeysByLayer[layer] else { return [] }
        return keys
            .sorted { shapeOrder($0) < shapeOrder($1) }
            .compactMap { key in
                guard let shape = shapeByKey[key] else {
                    return nil
                }
                return (key: key, shape: shape)
            }
    }

    func layerDensityIsRestrictive(_ layer: LayoutLayerID) -> Bool {
        tech.ruleSet(for: layer).map(densityRuleIsRestrictive) ?? false
    }

    func rebuildNetIndexes() {
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
        viaHaloByLayer = [:]
        for via in topVias {
            insertViaIntoNetIndex(key: .top(via.id), via: via)
        }
        for (index, via) in childVias.enumerated() {
            insertViaIntoNetIndex(key: .child(index), via: via)
        }
    }

    func insertShapeIntoGrid(key: FlatShapeKey, shape: LayoutShape) {
        shapeByKey[key] = shape
        shapeKeysByLayer[shape.layer, default: []].insert(key)
        if !service.isManhattanShape(shape, dbu: tech.units.scale.databaseUnitsPerMicrometer) {
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

    func removeShapeFromGrid(key: FlatShapeKey, shape: LayoutShape) {
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

    func insertViaIntoNetIndex(key: FlatViaKey, via: LayoutVia) {
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
            viaHaloByLayer[layer, default: [:]][key] = halo
            viaHaloGridByLayer[layer]?.insert(key: key, box: halo)
        }
    }

    func removeViaFromNetIndex(key: FlatViaKey, via: LayoutVia) {
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
            viaHaloByLayer[layer]?[key] = nil
            if viaHaloByLayer[layer]?.isEmpty == true {
                viaHaloByLayer[layer] = nil
            }
            viaHaloGridByLayer[layer]?.remove(key: key)
        }
    }

    func viaHalo(for via: LayoutVia, on layer: LayoutLayerID) -> LayoutRect? {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { return nil }
        let enclosure: Double
        if layer == def.topLayer {
            enclosure = def.enclosure.top
        } else if layer == def.bottomLayer {
            enclosure = def.enclosure.bottom
        } else {
            return nil
        }
        let roundingSlack = 1.0 / tech.units.scale.databaseUnitsPerMicrometer
        return service.viaCutBoundingBox(for: via, tech: tech)
            .expanded(by: enclosure + roundingSlack, enclosure + roundingSlack)
    }

    func shapeOrder(_ key: FlatShapeKey) -> Int {
        switch key {
        case .top(let id):
            shapeIndexByID[id] ?? Int.max
        case .child(let index):
            topShapes.count + index
        }
    }

    func viaOrder(_ key: FlatViaKey) -> Int {
        switch key {
        case .top(let id):
            viaIndexByID[id] ?? Int.max
        case .child(let index):
            topVias.count + index
        }
    }
}
