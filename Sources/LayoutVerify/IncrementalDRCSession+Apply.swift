import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    /// Applies a geometry delta and re-verifies every check unit the edit
    /// can influence. The returned snapshot is exact except for the kinds
    /// listed in its `staleKinds`.
    public func apply(_ delta: LayoutEditDelta) throws -> IncrementalDRCUpdate {
        let clock = ContinuousClock()
        let start = clock.now

        if !tech.derivedLayerRules.isEmpty {
            return try applyByFullDerivedLayerRebuild(
                delta,
                clock: clock,
                start: start
            )
        }

        try validate(delta, shapeIndexByID: shapeIndexByID, viaIndexByID: viaIndexByID)

        var analysis = try analyze(delta)
        try mutateEditableShapes(delta)
        try mutateEditableVias(delta)

        let affectedViaKeys = expandAffectedViaKeys(using: &analysis)
        refreshLayerBuckets(using: analysis)
        refreshEnclosureBuckets(dirtyLayers: analysis.dirtyLayers)
        refreshSpacingBucketsIfNeeded(delta)
        refreshDensityBuckets(using: analysis)
        refreshShortBuckets(editedShapeIDs: analysis.editedShapeIDs)
        refreshOpenBuckets(using: analysis)
        let recomputedViaCount = refreshViaEnclosureBuckets(
            affectedViaIDs: analysis.affectedViaIDs,
            affectedViaKeys: affectedViaKeys
        )
        refreshGlobalBucketsIfNeeded(delta)
        refreshAntennaStalenessIfNeeded(delta)

        return makeApplyUpdate(
            clock: clock,
            start: start,
            dirtyLayers: analysis.dirtyLayers,
            recomputedViaCount: recomputedViaCount,
            recomputedNetCount: analysis.affectedNets.count
        )
    }

    private func analyze(_ delta: LayoutEditDelta) throws -> IncrementalDRCApplyAnalysis {
        var analysis = IncrementalDRCApplyAnalysis()
        try analyzeShapeDelta(delta, into: &analysis)
        try analyzeViaDelta(delta, into: &analysis)
        return analysis
    }

    private func analyzeShapeDelta(
        _ delta: LayoutEditDelta,
        into analysis: inout IncrementalDRCApplyAnalysis
    ) throws {
        for shape in delta.addedShapes {
            analysis.markShape(shape, forcesOpenRecompute: true)
            analysis.idListChangedLayers.insert(shape.layer)
        }
        for shape in delta.updatedShapes {
            let old = try existingShape(id: shape.id)
            let sameNet = old.netID == shape.netID
            analysis.markShape(old, forcesOpenRecompute: !sameNet)
            analysis.markShape(shape, forcesOpenRecompute: !sameNet)
            if sameNet, let netID = shape.netID, openByNet[netID] == nil {
                analysis.shapeOpenContactsBefore[shape.id] = (
                    netID,
                    openContacts(forShapeKey: .top(shape.id), shape: old)
                )
            }
            if old.layer != shape.layer {
                analysis.idListChangedLayers.insert(old.layer)
                analysis.idListChangedLayers.insert(shape.layer)
            }
        }
        for id in delta.removedShapeIDs {
            let old = try existingShape(id: id)
            analysis.markShape(old, forcesOpenRecompute: true)
            analysis.idListChangedLayers.insert(old.layer)
        }
    }

    private func analyzeViaDelta(
        _ delta: LayoutEditDelta,
        into analysis: inout IncrementalDRCApplyAnalysis
    ) throws {
        for via in delta.addedVias {
            analysis.affectedViaIDs.insert(via.id)
            if let netID = via.netID {
                analysis.affectedNets.insert(netID)
                analysis.openMustRecomputeNets.insert(netID)
            }
        }
        for via in delta.updatedVias {
            let old = try existingVia(id: via.id)
            analysis.affectedViaIDs.insert(via.id)
            let sameNet = old.netID == via.netID
            if let netID = old.netID {
                analysis.affectedNets.insert(netID)
                if !sameNet { analysis.openMustRecomputeNets.insert(netID) }
            }
            if let netID = via.netID {
                analysis.affectedNets.insert(netID)
                if !sameNet { analysis.openMustRecomputeNets.insert(netID) }
            }
            if sameNet, let netID = via.netID, openByNet[netID] == nil {
                analysis.viaOpenContactsBefore[via.id] = (
                    netID,
                    openContacts(forViaKey: .top(via.id), via: old)
                )
            }
        }
        for id in delta.removedViaIDs {
            let old = try existingVia(id: id)
            analysis.affectedViaIDs.insert(id)
            if let netID = old.netID {
                analysis.affectedNets.insert(netID)
                analysis.openMustRecomputeNets.insert(netID)
            }
        }
    }

    private func mutateEditableShapes(_ delta: LayoutEditDelta) throws {
        for shape in delta.updatedShapes {
            let old = try existingShape(id: shape.id)
            removeShapeFromGrid(key: .top(shape.id), shape: old)
        }
        for id in delta.removedShapeIDs {
            let old = try existingShape(id: id)
            removeShapeFromGrid(key: .top(id), shape: old)
        }
        for shape in delta.updatedShapes {
            let index = try shapeIndex(for: shape.id)
            topShapes[index] = shape
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
        for shape in delta.updatedShapes + delta.addedShapes {
            insertShapeIntoGrid(key: .top(shape.id), shape: shape)
        }
    }

    private func mutateEditableVias(_ delta: LayoutEditDelta) throws {
        for via in delta.updatedVias {
            let old = try existingVia(id: via.id)
            removeViaFromNetIndex(key: .top(via.id), via: old)
        }
        for id in delta.removedViaIDs {
            let old = try existingVia(id: id)
            removeViaFromNetIndex(key: .top(id), via: old)
        }
        for via in delta.updatedVias {
            let index = try viaIndex(for: via.id)
            topVias[index] = via
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
        for via in delta.updatedVias + delta.addedVias {
            insertViaIntoNetIndex(key: .top(via.id), via: via)
        }
    }

    private func expandAffectedViaKeys(
        using analysis: inout IncrementalDRCApplyAnalysis
    ) -> Set<FlatViaKey> {
        var affectedViaKeys: Set<FlatViaKey> = []
        for id in analysis.affectedViaIDs {
            affectedViaKeys.formUnion(viaKeysByID[id] ?? [])
        }
        for layer in analysis.dirtyLayers {
            guard let grid = viaHaloGridByLayer[layer],
                  let halos = viaHaloByLayer[layer],
                  let rects = analysis.dirtyRectsByLayer[layer] else { continue }
            for rect in rects {
                for key in grid.candidateKeys(of: rect) {
                    guard let via = viaByKey[key],
                          !analysis.affectedViaIDs.contains(via.id),
                          let halo = halos[key],
                          halo.intersects(rect) else {
                        continue
                    }
                    analysis.affectedViaIDs.insert(via.id)
                    affectedViaKeys.formUnion(viaKeysByID[via.id] ?? [])
                }
            }
        }
        return affectedViaKeys
    }

    private func refreshLayerBuckets(using analysis: IncrementalDRCApplyAnalysis) {
        for layer in analysis.dirtyLayers {
            refreshCoverageBucket(layer: layer)
            refreshShapeRuleBuckets(layer: layer)
            updateLayerClusters(
                layer: layer,
                editedKeys: analysis.editedKeysByLayer[layer] ?? [],
                dirtyRects: analysis.dirtyRectsByLayer[layer] ?? []
            )
        }
    }

    private func refreshCoverageBucket(layer: LayoutLayerID) {
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
    }

    private func refreshShapeRuleBuckets(layer: LayoutLayerID) {
        let layerRule = tech.ruleSet(for: layer)
        guard layerRule?.requiresRectangular == true
                || layerRule?.allowedAngleStepDegrees != nil else {
            setBucket(&rectOnlyByLayer, layer, [])
            setBucket(&angleByLayer, layer, [])
            return
        }

        let layerShapes = currentLayerPairs(layer: layer).map(\.shape)
        if layerRule?.requiresRectangular == true {
            setBucket(
                &rectOnlyByLayer, layer,
                service.checkRectangularGeometry(shapes: layerShapes, tech: tech)
            )
        } else {
            setBucket(&rectOnlyByLayer, layer, [])
        }
        if layerRule?.allowedAngleStepDegrees != nil {
            setBucket(
                &angleByLayer, layer,
                service.checkAngleRules(shapes: layerShapes, tech: tech)
            )
        } else {
            setBucket(&angleByLayer, layer, [])
        }
    }

    private func refreshEnclosureBuckets(dirtyLayers: Set<LayoutLayerID>) {
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
    }

    private func refreshSpacingBucketsIfNeeded(_ delta: LayoutEditDelta) {
        guard !delta.isEmpty, !tech.spacingRules.isEmpty else { return }
        spacingByRuleID = [:]
        for (ruleID, rules) in Dictionary(grouping: tech.spacingRules, by: service.spacingRuleID) {
            let fresh = service.checkSpacingRules(shapes: topShapes + childShapes, tech: tech, rules: rules)
            if !fresh.isEmpty { spacingByRuleID[ruleID] = fresh }
        }
    }

    private func refreshDensityBuckets(using analysis: IncrementalDRCApplyAnalysis) {
        guard densityIsTracked else { return }
        let newOverall = service.overallBoundingBox(shapes: topShapes + childShapes)
        if newOverall != overallBoundingBox {
            rebuildAllDensityBuckets(overall: newOverall)
        } else if let overall = newOverall {
            refreshDirtyDensityBuckets(using: analysis, overall: overall)
        }
    }

    private func rebuildAllDensityBuckets(overall newOverall: LayoutRect?) {
        overallBoundingBox = newOverall
        densityStateByLayer = [:]
        guard let overall = newOverall else { return }
        for layer in shapeKeysByLayer.keys where layerDensityIsRestrictive(layer) {
            rebuildLayerDensity(
                layer: layer,
                layerPairs: currentLayerPairs(layer: layer),
                overall: overall
            )
        }
    }

    private func refreshDirtyDensityBuckets(
        using analysis: IncrementalDRCApplyAnalysis,
        overall: LayoutRect
    ) {
        for layer in analysis.dirtyLayers where layerDensityIsRestrictive(layer) {
            updateLayerDensity(
                layer: layer,
                layerPairs: currentLayerPairs(layer: layer),
                editedKeys: analysis.editedKeysByLayer[layer] ?? [],
                dirtyRects: analysis.dirtyRectsByLayer[layer] ?? [],
                idListChanged: analysis.idListChangedLayers.contains(layer),
                overall: overall
            )
        }
    }

    private func refreshShortBuckets(editedShapeIDs: Set<UUID>) {
        shortViolations.removeAll { !Set($0.shapeIDs).isDisjoint(with: editedShapeIDs) }
        shortViolations.append(contentsOf: recomputeShorts(editedShapeIDs: editedShapeIDs))
    }

    private func refreshOpenBuckets(using analysis: IncrementalDRCApplyAnalysis) {
        var openSkipNets = Set(analysis.affectedNets.filter {
            openByNet[$0] == nil && !analysis.openMustRecomputeNets.contains($0)
        })
        for (shapeID, before) in analysis.shapeOpenContactsBefore {
            guard openSkipNets.contains(before.netID),
                  let shape = shapeByKey[.top(shapeID)] else { continue }
            let after = openContacts(forShapeKey: .top(shapeID), shape: shape)
            if after != before.contacts {
                openSkipNets.remove(before.netID)
            }
        }
        for (viaID, before) in analysis.viaOpenContactsBefore {
            guard openSkipNets.contains(before.netID),
                  let via = viaByKey[.top(viaID)] else { continue }
            let after = openContacts(forViaKey: .top(viaID), via: via)
            if after != before.contacts {
                openSkipNets.remove(before.netID)
            }
        }
        for netID in analysis.affectedNets {
            if openSkipNets.contains(netID) { continue }
            let fresh = checkOpen(netID: netID)
            openByNet[netID] = fresh.isEmpty ? nil : fresh
        }
    }

    private func refreshViaEnclosureBuckets(
        affectedViaIDs: Set<UUID>,
        affectedViaKeys: Set<FlatViaKey>
    ) -> Int {
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
        return recomputeVias.count
    }

    private func refreshGlobalBucketsIfNeeded(_ delta: LayoutEditDelta) {
        guard !delta.isEmpty else { return }
        if !tech.minimumCutRules.isEmpty {
            minimumCutViolations = service.checkMinimumCuts(
                shapes: topShapes + childShapes,
                vias: topVias + childVias,
                tech: tech
            )
        }
        if !tech.forbiddenLayerRules.isEmpty {
            forbiddenLayerViolations = service.checkForbiddenLayers(
                shapes: topShapes + childShapes,
                tech: tech
            )
        }
        if !tech.exactOverlapRules.isEmpty {
            exactOverlapViolations = service.checkExactOverlaps(
                shapes: topShapes + childShapes,
                tech: tech
            )
        }
    }

    private func refreshAntennaStalenessIfNeeded(_ delta: LayoutEditDelta) {
        if !delta.isEmpty && !tech.antennaRules.isEmpty {
            antennaIsStale = true
        }
    }

    private func makeApplyUpdate(
        clock: ContinuousClock,
        start: ContinuousClock.Instant,
        dirtyLayers: Set<LayoutLayerID>,
        recomputedViaCount: Int,
        recomputedNetCount: Int
    ) -> IncrementalDRCUpdate {
        IncrementalDRCUpdate(
            result: assembleResult(),
            staleKinds: staleKinds,
            recomputedLayers: dirtyLayers.sorted(by: Self.layerOrder),
            recomputedViaCount: recomputedViaCount,
            recomputedNetCount: recomputedNetCount,
            duration: clock.now - start
        )
    }

    private func existingShape(id: UUID) throws -> LayoutShape {
        topShapes[try shapeIndex(for: id)]
    }

    private func existingVia(id: UUID) throws -> LayoutVia {
        topVias[try viaIndex(for: id)]
    }

    private func shapeIndex(for id: UUID) throws -> Int {
        guard let index = shapeIndexByID[id], topShapes.indices.contains(index) else {
            throw IncrementalDRCSessionError.unknownShapeID(id)
        }
        return index
    }

    private func viaIndex(for id: UUID) throws -> Int {
        guard let index = viaIndexByID[id], topVias.indices.contains(index) else {
            throw IncrementalDRCSessionError.unknownViaID(id)
        }
        return index
    }
}
