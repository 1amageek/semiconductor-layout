import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
    func checkMinimumCuts(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        tech: LayoutTechDatabase,
        sourceNets: [LayoutConductorSnapshot.Source: LayoutConductorSnapshot.NetReference]
    ) throws -> [LayoutViolation] {
        guard !tech.minimumCutRules.isEmpty else { return [] }

        let shapesByLayer = Dictionary(grouping: Array(shapes.enumerated()), by: { $0.element.layer })
        let dbu = tech.units.scale.databaseUnitsPerMicrometer
        var violations: [LayoutViolation] = []

        for rule in tech.minimumCutRules {
            guard rule.minimumCount > 0 else { continue }
            guard let bottomShapes = shapesByLayer[rule.bottomLayer], !bottomShapes.isEmpty else { continue }
            guard let topShapes = shapesByLayer[rule.topLayer], !topShapes.isEmpty else { continue }
            let explicitCutShapes = shapesByLayer[rule.cutLayer] ?? []
            let matchingVias = vias.enumerated().compactMap { entry -> (index: Int, via: LayoutVia, rects: [LayoutRect])? in
                let (index, via) = entry
                guard cutDefinitionMatchesMinimumCutRule(via.viaDefinitionID, rule: rule, tech: tech) else {
                    return nil
                }
                return (index: index, via: via, rects: viaCutRects(for: via, tech: tech))
            }

            for (bottomIndex, bottom) in bottomShapes {
                for (topIndex, top) in topShapes {
                    let sharedNetID: LayoutConductorSnapshot.NetReference?
                    if let bottomNetID = sourceNets[.shape(bottomIndex)] {
                        guard sourceNets[.shape(topIndex)] == bottomNetID else { continue }
                        sharedNetID = bottomNetID
                    } else {
                        guard sourceNets[.shape(topIndex)] == nil else { continue }
                        sharedNetID = nil
                    }
                    guard let overlap = try overlapRegion(
                        first: bottom.geometry,
                        second: top.geometry,
                        dbu: dbu
                    ) else {
                        continue
                    }

                    let explicitCutIDs = try explicitCutShapes.compactMap { entry -> UUID? in
                        let (cutIndex, cutShape) = entry
                        if let sharedNetID {
                            guard sourceNets[.shape(cutIndex)] == nil || sourceNets[.shape(cutIndex)] == sharedNetID else { return nil }
                        } else {
                            guard sourceNets[.shape(cutIndex)] == nil else { return nil }
                        }
                        guard try intersectsPositiveArea(cutShape.geometry, region: overlap.region, dbu: dbu) else {
                            return nil
                        }
                        return cutShape.id
                    }
                    var viaIDs: [UUID] = []
                    var seenViaIndices: Set<Int> = []
                    let viaCutCount = try matchingVias.reduce(into: 0) { count, entry in
                        if let sharedNetID {
                            guard sourceNets[.via(entry.index)] == nil || sourceNets[.via(entry.index)] == sharedNetID else { return }
                        } else {
                            guard sourceNets[.via(entry.index)] == nil else { return }
                        }
                        var contributed = false
                        for rect in entry.rects {
                            guard try intersectsPositiveArea(.rect(rect), region: overlap.region, dbu: dbu) else {
                                continue
                            }
                            count += 1
                            contributed = true
                        }
                        if contributed, seenViaIndices.insert(entry.index).inserted {
                            viaIDs.append(entry.via.id)
                        }
                    }
                    let cutCount = explicitCutIDs.count + viaCutCount
                    guard sharedNetID != nil || cutCount > 0 else { continue }
                    guard cutCount < rule.minimumCount else { continue }

                    violations.append(LayoutViolation(
                        kind: .minimumCut,
                        ruleID: minimumCutRuleID(rule),
                        message: "Minimum cut violation between \(rule.bottomLayer.name) and \(rule.topLayer.name). Required \(rule.minimumCount), found \(cutCount).",
                        layer: rule.cutLayer,
                        region: overlap.bounds,
                        measured: Double(cutCount),
                        required: Double(rule.minimumCount),
                        unit: "cut",
                        shapeIDs: [bottom.id, top.id] + explicitCutIDs,
                        viaIDs: viaIDs,
                        netIDs: sharedNetID.map { [$0.netID] } ?? [],
                        netReferences: sharedNetID.map { [$0] } ?? [],
                        suggestedFix: "Add cut features on \(rule.cutLayer.name) inside the overlap or reduce the conductor overlap so the connection is intentional and rule-clean."
                    ))
                }
            }
        }

        return violations
    }

    func checkExactOverlaps(
        shapes: [LayoutShape],
        tech: LayoutTechDatabase,
        rules: [LayoutExactOverlapRule]? = nil
    ) -> [LayoutViolation] {
        let exactRules = rules ?? tech.exactOverlapRules
        guard !exactRules.isEmpty else { return [] }

        let shapesByLayer = Dictionary(grouping: shapes, by: { $0.layer })
        var violations: [LayoutViolation] = []
        for rule in exactRules {
            let tolerance = max(0, rule.tolerance)
            let primaryShapes = shapesByLayer[rule.primaryLayer] ?? []
            let secondaryShapes = rule.secondaryLayers.flatMap { shapesByLayer[$0] ?? [] }
            let secondaryLayerNames = rule.secondaryLayers.map(\.name).joined(separator: " or ")
            for primary in primaryShapes {
                let primaryBox = LayoutGeometryAnalysis.boundingBox(for: primary.geometry)
                if secondaryShapes.contains(where: {
                    exactBounds(primaryBox, matches: LayoutGeometryAnalysis.boundingBox(for: $0.geometry), tolerance: tolerance)
                }) {
                    continue
                }
                let closestSecondary = closestExactOverlapCandidate(primaryBox, in: secondaryShapes)
                let measured = closestSecondary.map {
                    boundsMismatch(primaryBox, LayoutGeometryAnalysis.boundingBox(for: $0.geometry))
                }
                var shapeIDs = [primary.id]
                if let closestSecondary {
                    shapeIDs.append(closestSecondary.id)
                }
                let relatedShapes = [primary] + (closestSecondary.map { [$0] } ?? [])
                violations.append(LayoutViolation(
                    kind: .exactOverlap,
                    ruleID: exactOverlapRuleID(rule),
                    message: "Exact overlap violation between \(rule.primaryLayer.name) and \(secondaryLayerNames).",
                    layer: rule.primaryLayer,
                    region: primaryBox,
                    measured: measured,
                    required: tolerance,
                    unit: "um",
                    shapeIDs: shapeIDs,
                    netIDs: uniqueNetIDs(of: relatedShapes),
                    suggestedFix: "Create or resize geometry on \(secondaryLayerNames) so its bounds match the primary feature."
                ))
            }
        }
        return violations
    }

    private func exactBounds(
        _ first: LayoutRect,
        matches second: LayoutRect,
        tolerance: Double
    ) -> Bool {
        boundsMismatch(first, second) <= tolerance
    }

    private func boundsMismatch(_ first: LayoutRect, _ second: LayoutRect) -> Double {
        [
            abs(first.minX - second.minX),
            abs(first.minY - second.minY),
            abs(first.maxX - second.maxX),
            abs(first.maxY - second.maxY),
        ].max() ?? 0
    }

    private func closestExactOverlapCandidate(
        _ primaryBox: LayoutRect,
        in secondaryShapes: [LayoutShape]
    ) -> LayoutShape? {
        secondaryShapes.min {
            boundsMismatch(primaryBox, LayoutGeometryAnalysis.boundingBox(for: $0.geometry))
                < boundsMismatch(primaryBox, LayoutGeometryAnalysis.boundingBox(for: $1.geometry))
        }
    }

    private func cutDefinitionMatchesMinimumCutRule(
        _ definitionID: String,
        rule: LayoutMinimumCutRule,
        tech: LayoutTechDatabase
    ) -> Bool {
        if let via = tech.viaDefinition(for: definitionID) {
            return cutStackMatches(
                cutLayer: via.cutLayer,
                bottomLayer: via.bottomLayer,
                topLayer: via.topLayer,
                rule: rule
            )
        }
        if let contact = tech.contactDefinition(for: definitionID) {
            return cutStackMatches(
                cutLayer: contact.cutLayer,
                bottomLayer: contact.bottomLayer,
                topLayer: contact.topLayer,
                rule: rule
            )
        }
        return false
    }

    private func cutStackMatches(
        cutLayer: LayoutLayerID,
        bottomLayer: LayoutLayerID,
        topLayer: LayoutLayerID,
        rule: LayoutMinimumCutRule
    ) -> Bool {
        guard cutLayer == rule.cutLayer else { return false }
        let sameOrientation = bottomLayer == rule.bottomLayer && topLayer == rule.topLayer
        let reversedOrientation = bottomLayer == rule.topLayer && topLayer == rule.bottomLayer
        return sameOrientation || reversedOrientation
    }

    private func overlapRegion(
        first: LayoutGeometry,
        second: LayoutGeometry,
        dbu: Double
    ) throws -> (region: Region, bounds: LayoutRect)? {
        guard let firstBoundary = geometryToIRBoundary(first, dbu: dbu),
              let secondBoundary = geometryToIRBoundary(second, dbu: dbu) else {
            return nil
        }
        let overlap = try Region(polygons: [firstBoundary]).intersection(Region(polygons: [secondBoundary]))
        guard !overlap.isEmpty, let box = overlap.boundingBox else { return nil }
        guard box.maxX > box.minX, box.maxY > box.minY else { return nil }
        return (overlap, irBoundingBoxToRect(box, dbu: dbu))
    }

    private func intersectsPositiveArea(_ geometry: LayoutGeometry, region: Region, dbu: Double) throws -> Bool {
        guard let boundary = geometryToIRBoundary(geometry, dbu: dbu) else { return false }
        let intersection = try region.intersection(Region(polygons: [boundary]))
        guard !intersection.isEmpty, let bounds = intersection.boundingBox else { return false }
        return bounds.maxX > bounds.minX && bounds.maxY > bounds.minY
    }
}
