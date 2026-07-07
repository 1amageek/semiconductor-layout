import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    func checkViaEnclosure(vias: [LayoutVia]) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let roundingSlack = 1.0 / tech.units.dbuPerMicron
        for via in vias {
            guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            let cutBox = service.viaCutBoundingBox(for: via, tech: tech)
            let topHalo = cutBox.expanded(by: def.enclosure.top, def.enclosure.top)
            let bottomHalo = cutBox.expanded(by: def.enclosure.bottom, def.enclosure.bottom)
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

    func shapeCandidates(
        layer: LayoutLayerID,
        near rect: LayoutRect,
        margin: Double
    ) -> [LayoutShape] {
        guard let grid = shapeGridByLayer[layer] else { return [] }
        let probe = rect.expanded(by: margin, margin)
        return grid.candidateKeys(of: rect, margin: margin).compactMap { key in
            guard let shape = shapeByKey[key],
                  LayoutGeometryAnalysis.boundingBox(for: shape.geometry).intersects(probe) else {
                return nil
            }
            return shape
        }
    }

    func rebuildLayerDensity(
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

    func updateLayerDensity(
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

    func densityRuleIsRestrictive(_ rules: LayoutLayerRuleSet) -> Bool {
        rules.minDensity > 0 || rules.maxDensity < 1
    }

    func refreshDensityVerdict(
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
}
