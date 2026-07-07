import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
    func checkViaEnclosure(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        tech: LayoutTechDatabase
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        guard !vias.isEmpty else { return violations }
        let dbu = tech.units.dbuPerMicron

        // Group shapes and build spatial indices per layer once; each via
        // then only merges the geometry near its own cut. Shapes outside the
        // required halo contribute nothing to halo coverage, point coverage,
        // or the measured value, so the verdict is unchanged.
        let shapesByLayer = Dictionary(grouping: shapes, by: { $0.layer })
        var gridsByLayer: [LayoutLayerID: ShapeGridIndex] = [:]
        for (layer, layerShapes) in shapesByLayer {
            let boxes = layerShapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
            gridsByLayer[layer] = ShapeGridIndex(
                boundingBoxes: boxes,
                cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
            )
        }
        // Rounding to database units moves edges by at most half a dbu, so
        // the candidate query adds one dbu of slack around the halo.
        let roundingSlack = 1.0 / dbu
        func candidates(layer: LayoutLayerID, nearHalo halo: LayoutRect) -> [LayoutShape] {
            guard let layerShapes = shapesByLayer[layer],
                  let grid = gridsByLayer[layer] else { return [] }
            return grid.candidateIndices(near: halo, margin: roundingSlack).map { layerShapes[$0] }
        }

        for via in vias {
            guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            for cutRect in viaCutRects(for: via, tech: tech) {
                let topCandidates = candidates(
                    layer: def.topLayer,
                    nearHalo: cutRect.expanded(by: def.enclosure.top, def.enclosure.top)
                ) + explicitViaLayerShapes(for: via, layer: def.topLayer, tech: tech)
                let bottomCandidates = candidates(
                    layer: def.bottomLayer,
                    nearHalo: cutRect.expanded(by: def.enclosure.bottom, def.enclosure.bottom)
                ) + explicitViaLayerShapes(for: via, layer: def.bottomLayer, tech: tech)
                let topCheck = viaEnclosureCheck(
                    cutRect: cutRect,
                    enclosure: def.enclosure.top,
                    candidates: topCandidates,
                    dbu: dbu
                )
                let bottomCheck = viaEnclosureCheck(
                    cutRect: cutRect,
                    enclosure: def.enclosure.bottom,
                    candidates: bottomCandidates,
                    dbu: dbu
                )

                if let violation = viaEnclosureViolation(
                    via: via,
                    definition: def,
                    cutRect: cutRect,
                    topCheck: topCheck,
                    bottomCheck: bottomCheck
                ) {
                    violations.append(violation)
                }
            }
        }
        return violations
    }

    func viaEnclosureViolation(
        for via: LayoutVia,
        topCandidates: [LayoutShape],
        bottomCandidates: [LayoutShape],
        tech: LayoutTechDatabase
    ) -> LayoutViolation? {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { return nil }
        let dbu = tech.units.dbuPerMicron
        let effectiveTopCandidates = topCandidates
            + explicitViaLayerShapes(for: via, layer: def.topLayer, tech: tech)
        let effectiveBottomCandidates = bottomCandidates
            + explicitViaLayerShapes(for: via, layer: def.bottomLayer, tech: tech)
        for cutRect in viaCutRects(for: via, tech: tech) {
            let topCheck = viaEnclosureCheck(
                cutRect: cutRect,
                enclosure: def.enclosure.top,
                candidates: effectiveTopCandidates,
                dbu: dbu
            )
            let bottomCheck = viaEnclosureCheck(
                cutRect: cutRect,
                enclosure: def.enclosure.bottom,
                candidates: effectiveBottomCandidates,
                dbu: dbu
            )
            if let violation = viaEnclosureViolation(
                via: via,
                definition: def,
                cutRect: cutRect,
                topCheck: topCheck,
                bottomCheck: bottomCheck
            ) {
                return violation
            }
        }
        return nil
    }

    private func explicitViaLayerShapes(
        for via: LayoutVia,
        layer: LayoutLayerID,
        tech: LayoutTechDatabase
    ) -> [LayoutShape] {
        explicitViaLayerRects(for: via, layer: layer, tech: tech).map {
            LayoutShape(layer: layer, netID: via.netID, geometry: .rect($0))
        }
    }

    func checkEnclosureRules(
        shapes: [LayoutShape],
        tech: LayoutTechDatabase,
        rules: [LayoutEnclosureRule]? = nil
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let dbu = tech.units.dbuPerMicron
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })

        for rule in rules ?? tech.enclosureRules {
            guard let outerShapes = grouped[rule.outerLayer], !outerShapes.isEmpty else { continue }
            guard let innerShapes = grouped[rule.innerLayer], !innerShapes.isEmpty else { continue }

            let minEncDBU = Int32((rule.minEnclosure * dbu).rounded())
            if minEncDBU <= 0 { continue }

            let outerRegion = mergedRegion(of: outerShapes, dbu: dbu)
            let innerRegion = mergedRegion(of: innerShapes, dbu: dbu)

            for component in innerRegion.connectedComponents() {
                let covered = component.and(outerRegion)
                if covered.isEmpty { continue }

                let protrusion = component.not(outerRegion)
                if !protrusion.isEmpty && !rule.allowsPassThrough {
                    for part in protrusion.connectedComponents() {
                        guard let bb = part.boundingBox else { continue }
                        let rect = irBoundingBoxToRect(bb, dbu: dbu)
                        violations.append(enclosureRuleViolation(
                            rule: rule,
                            rect: rect,
                            measured: 0,
                            message: "Enclosure violation: \(rule.innerLayer.name) extends outside \(rule.outerLayer.name), which must enclose it by at least \(rule.minEnclosure)µm",
                            innerShapes: innerShapes,
                            outerShapes: outerShapes
                        ))
                    }
                }

                // The halo of the covered part must stay inside the outer
                // layer. Pass-through crossings are masked by the protrusion
                // halo so the clip line never reads as a margin of zero, and
                // margin deficits already implied by a reported protrusion are
                // not double-counted.
                var missing = covered.sized(by: minEncDBU).not(outerRegion)
                if !protrusion.isEmpty {
                    missing = missing.not(protrusion.sized(by: minEncDBU))
                }
                for deficit in missing.connectedComponents() {
                    guard let bb = deficit.boundingBox else { continue }
                    let rect = irBoundingBoxToRect(bb, dbu: dbu)
                    let measured = max(0, rule.minEnclosure - deficitThickness(deficit, dbu: dbu))
                    violations.append(enclosureRuleViolation(
                        rule: rule,
                        rect: rect,
                        measured: measured,
                        message: "Enclosure violation: \(rule.innerLayer.name) must be enclosed by \(rule.outerLayer.name) by at least \(rule.minEnclosure)µm, measured \(String(format: "%.3f", measured))µm",
                        innerShapes: innerShapes,
                        outerShapes: outerShapes
                    ))
                }
            }
        }
        return violations
    }

    private func deficitThickness(_ deficit: Region, dbu: Double) -> Double {
        var minDimension = Double.infinity
        for polygon in deficit.polygons {
            let xs = polygon.points.map(\.x)
            let ys = polygon.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { continue }
            minDimension = min(minDimension, Double(min(maxX - minX, maxY - minY)))
        }
        return minDimension.isFinite ? minDimension / dbu : 0
    }

    private func enclosureRuleViolation(
        rule: LayoutEnclosureRule,
        rect: LayoutRect,
        measured: Double,
        message: String,
        innerShapes: [LayoutShape],
        outerShapes: [LayoutShape]
    ) -> LayoutViolation {
        let innerContributors = contributingShapes(innerShapes, around: rect)
        let outerContributors = contributingShapes(outerShapes, around: rect)
        return LayoutViolation(
            kind: .enclosure,
            ruleID: enclosureRuleID(rule),
            message: message,
            layer: rule.innerLayer,
            region: rect,
            measured: measured,
            required: rule.minEnclosure,
            unit: "um",
            shapeIDs: (innerContributors + outerContributors).map(\.id),
            netIDs: uniqueNetIDs(of: innerContributors),
            suggestedFix: "Expand the outer layer or shrink the inner layer to satisfy enclosure."
        )
    }

    func checkExtensionRules(
        shapes: [LayoutShape],
        tech: LayoutTechDatabase,
        rules: [LayoutExtensionRule]? = nil
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })

        for rule in rules ?? tech.extensionRules {
            guard rule.minExtension > 0 else { continue }
            guard let extendingShapes = grouped[rule.extendingLayer], !extendingShapes.isEmpty else { continue }
            guard let enclosedShapes = grouped[rule.enclosedLayer], !enclosedShapes.isEmpty else { continue }

            for enclosedShape in enclosedShapes {
                let enclosedBox = LayoutGeometryAnalysis.boundingBox(for: enclosedShape.geometry)
                let bestCandidate = extendingShapes
                    .compactMap { extendingShape -> (shape: LayoutShape, box: LayoutRect, measurement: Double)? in
                        let extendingBox = LayoutGeometryAnalysis.boundingBox(for: extendingShape.geometry)
                        guard let measurement = extensionMeasurement(
                            direction: rule.direction,
                            extending: extendingBox,
                            enclosed: enclosedBox
                        ) else {
                            return nil
                        }
                        return (extendingShape, extendingBox, measurement)
                    }
                    .max { $0.measurement < $1.measurement }

                let measured = bestCandidate?.measurement ?? 0
                guard measured + Self.numericalTolerance < rule.minExtension else { continue }

                let region = bestCandidate?.box.union(enclosedBox) ?? enclosedBox
                let shapeIDs = [enclosedShape.id] + [bestCandidate?.shape.id].compactMap { $0 }
                let relatedShapes = [enclosedShape] + [bestCandidate?.shape].compactMap { $0 }
                violations.append(LayoutViolation(
                    kind: .extension,
                    ruleID: extensionRuleID(rule),
                    message: "Extension violation: \(rule.extendingLayer.name) must extend \(rule.direction.rawValue)ly beyond \(rule.enclosedLayer.name) by at least \(rule.minExtension)µm, measured \(String(format: "%.3f", measured))µm",
                    layer: rule.extendingLayer,
                    region: region,
                    measured: measured,
                    required: rule.minExtension,
                    unit: "um",
                    shapeIDs: shapeIDs,
                    netIDs: uniqueNetIDs(of: relatedShapes),
                    suggestedFix: "Extend \(rule.extendingLayer.name) \(rule.direction.rawValue)ly beyond \(rule.enclosedLayer.name) or adjust the device geometry."
                ))
            }
        }
        return violations
    }

    private func extensionMeasurement(
        direction: LayoutExtensionRule.Direction,
        extending: LayoutRect,
        enclosed: LayoutRect
    ) -> Double? {
        switch direction {
        case .horizontal:
            guard intervalsOverlap(extending.minY, extending.maxY, enclosed.minY, enclosed.maxY) else {
                return nil
            }
            return min(enclosed.minX - extending.minX, extending.maxX - enclosed.maxX)
        case .vertical:
            guard intervalsOverlap(extending.minX, extending.maxX, enclosed.minX, enclosed.maxX) else {
                return nil
            }
            return min(enclosed.minY - extending.minY, extending.maxY - enclosed.maxY)
        }
    }

    private func intervalsOverlap(_ firstMin: Double, _ firstMax: Double, _ secondMin: Double, _ secondMax: Double) -> Bool {
        firstMin <= secondMax && secondMin <= firstMax
    }

    private struct ViaEnclosureCheck: Sendable {
        let passed: Bool
        let measured: Double
    }

    private func viaEnclosureViolation(
        via: LayoutVia,
        definition: LayoutViaDefinition,
        cutRect: LayoutRect,
        topCheck: ViaEnclosureCheck,
        bottomCheck: ViaEnclosureCheck
    ) -> LayoutViolation? {
        guard !topCheck.passed || !bottomCheck.passed else { return nil }
        let missing = [
            topCheck.passed ? nil : "top \(definition.topLayer.name)",
            bottomCheck.passed ? nil : "bottom \(definition.bottomLayer.name)"
        ].compactMap { $0 }.joined(separator: ", ")
        return LayoutViolation(
            kind: .enclosure,
            ruleID: "via.\(via.viaDefinitionID).enclosure",
            message: "Via enclosure violation for \(via.viaDefinitionID): missing \(missing)",
            layer: definition.cutLayer,
            region: cutRect,
            measured: min(topCheck.measured, bottomCheck.measured),
            required: max(definition.enclosure.top, definition.enclosure.bottom),
            unit: "um",
            viaIDs: [via.id],
            netIDs: [via.netID].compactMap { $0 },
            suggestedFix: "Add top and bottom metal coverage around the via cut."
        )
    }

    private func viaEnclosureCheck(
        cutRect: LayoutRect,
        enclosure: Double,
        candidates: [LayoutShape],
        dbu: Double
    ) -> ViaEnclosureCheck {
        guard !candidates.isEmpty else {
            return ViaEnclosureCheck(passed: false, measured: 0)
        }
        let requiredRect = cutRect.expanded(by: enclosure, enclosure)
        if let fastCheck = rectangularViaEnclosureCheck(
            cutRect: cutRect,
            requiredRect: requiredRect,
            candidates: candidates
        ) {
            return fastCheck
        }

        // Coverage of the required halo by the merged candidate region is the
        // authoritative test: several abutting shapes may jointly enclose the
        // cut even when no single shape does. The single-shape `measured`
        // value is kept for reporting only.
        let outerRegion = shapesToRegion(candidates, dbu: dbu)
        let requiredRegion = rectToRegion(requiredRect, dbu: dbu)
        let missingCoverage = requiredRegion.not(outerRegion)
        let pointCoverage = requiredEnclosurePoints(cutRect: cutRect, enclosure: enclosure).allSatisfy { point in
            candidates.contains { LayoutGeometryAnalysis.contains(point, in: $0.geometry) }
        }
        let measured = measuredEnclosure(cutRect: cutRect, shapes: candidates)
        return ViaEnclosureCheck(
            passed: missingCoverage.isEmpty && pointCoverage,
            measured: measured
        )
    }

    private func rectangularViaEnclosureCheck(
        cutRect: LayoutRect,
        requiredRect: LayoutRect,
        candidates: [LayoutShape]
    ) -> ViaEnclosureCheck? {
        var best: Double?
        for candidate in candidates {
            guard case .rect(let rect) = candidate.geometry,
                  rect.minX <= requiredRect.minX,
                  rect.maxX >= requiredRect.maxX,
                  rect.minY <= requiredRect.minY,
                  rect.maxY >= requiredRect.maxY else {
                continue
            }
            let measured = min(
                cutRect.minX - rect.minX,
                rect.maxX - cutRect.maxX,
                cutRect.minY - rect.minY,
                rect.maxY - cutRect.maxY
            )
            best = max(best ?? 0, measured)
        }
        guard let measured = best else { return nil }
        return ViaEnclosureCheck(passed: true, measured: max(0, measured))
    }

    private func requiredEnclosurePoints(cutRect: LayoutRect, enclosure: Double) -> [LayoutPoint] {
        let rect = cutRect.expanded(by: enclosure, enclosure)
        return [
            rect.center,
            LayoutPoint(x: rect.minX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    private func measuredEnclosure(cutRect: LayoutRect, shapes: [LayoutShape]) -> Double {
        var best = 0.0
        for shape in shapes {
            let bbox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            guard bbox.intersects(cutRect) || bbox.contains(cutRect.center) else { continue }
            let measured = min(
                cutRect.minX - bbox.minX,
                bbox.maxX - cutRect.maxX,
                cutRect.minY - bbox.minY,
                bbox.maxY - cutRect.maxY
            )
            best = max(best, measured)
        }
        return max(0, best)
    }
}
