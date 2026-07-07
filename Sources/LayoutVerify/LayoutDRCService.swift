import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

public struct LayoutDRCService {
    static let numericalTolerance = 1.0e-12

    public init() {}

    public func run(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) -> LayoutDRCResult {
        guard let context = makeRunContext(document: document, tech: tech, cellID: cellID) else {
            return LayoutDRCResult(diagnostics: [missingTargetCellDiagnostic(document: document, cellID: cellID)])
        }
        return LayoutDRCResult(violations: collectViolations(context: context, tech: tech))
    }

    public func runChecked(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws -> LayoutDRCResult {
        guard let context = makeRunContext(document: document, tech: tech, cellID: cellID) else {
            throw LayoutDRCServiceError.targetCellNotFound(
                requestedCellID: cellID,
                topCellID: document.topCellID
            )
        }
        return LayoutDRCResult(violations: collectViolations(context: context, tech: tech))
    }

    private func makeRunContext(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID?
    ) -> LayoutDRCRunContext? {
        let checkedDocument = LayoutDerivedLayerMaterializer.materialize(document: document, tech: tech)
        guard let targetCell = resolveCell(document: checkedDocument, cellID: cellID) else {
            return nil
        }

        var flattenedShapes: [LayoutShape] = []
        var flattenedVias: [LayoutVia] = []
        var flattenedPins: [LayoutPin] = []
        var terminalConflicts: [TerminalConnectivityConflict] = []
        flatten(
            cell: targetCell,
            document: checkedDocument,
            tech: tech,
            transforms: [],
            terminalNetIDs: [:],
            shapes: &flattenedShapes,
            vias: &flattenedVias,
            pins: &flattenedPins,
            terminalConflicts: &terminalConflicts
        )

        return LayoutDRCRunContext(
            shapes: flattenedShapes,
            vias: flattenedVias,
            pins: flattenedPins,
            terminalConflicts: terminalConflicts
        )
    }

    private func collectViolations(
        context: LayoutDRCRunContext,
        tech: LayoutTechDatabase
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []

        violations.append(contentsOf: context.terminalConflicts.map(makeTerminalConflictViolation))
        violations.append(contentsOf: checkRuleCoverage(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkForbiddenLayers(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkWidthAndArea(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkRectangularGeometry(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkAngleRules(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkSpacing(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkSpacingRules(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkViaEnclosure(shapes: context.shapes, vias: context.vias, tech: tech))
        violations.append(contentsOf: checkMinimumCuts(shapes: context.shapes, vias: context.vias, tech: tech))
        violations.append(contentsOf: checkExactOverlaps(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkEnclosureRules(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkExtensionRules(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkDensity(shapes: context.shapes, tech: tech))
        violations.append(contentsOf: checkShorts(shapes: context.shapes))
        violations.append(contentsOf: checkOpens(shapes: context.shapes, vias: context.vias, tech: tech))
        violations.append(contentsOf: checkAntenna(
            shapes: context.shapes,
            vias: context.vias,
            pins: context.pins,
            tech: tech
        ))

        return violations
    }

    private func missingTargetCellDiagnostic(
        document: LayoutDocument,
        cellID: UUID?
    ) -> LayoutDRCDiagnostic {
        let target = cellID ?? document.topCellID
        return LayoutDRCDiagnostic(
            code: "drc.target_cell_not_found",
            severity: .error,
            message: "DRC target cell could not be resolved.",
            cellID: target,
            suggestedActions: [
                "inspect_document_cells",
                "set_valid_top_cell",
                "pass_existing_cell_id"
            ]
        )
    }

    func checkRuleCoverage(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        return grouped.compactMap { layer, layerShapes in
            guard tech.ruleSet(for: layer) == nil,
                  !tech.forbiddenLayerRules.contains(where: { $0.layer == layer }) else {
                return nil
            }
            return LayoutViolation(
                kind: .ruleCoverage,
                ruleID: layerRuleID(layer: layer, rule: "ruleCoverage"),
                message: "Layer \(layer.name) has geometry but no DRC rule set.",
                layer: layer,
                region: overallBoundingBox(shapes: layerShapes) ?? .zero,
                shapeIDs: layerShapes.map(\.id),
                suggestedFix: "Add a layer rule set for this layer or remove geometry from unchecked layers."
            )
        }
    }

    func checkForbiddenLayers(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        guard !tech.forbiddenLayerRules.isEmpty else { return [] }
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        return tech.forbiddenLayerRules.flatMap { rule -> [LayoutViolation] in
            let layerShapes = grouped[rule.layer] ?? []
            return layerShapes.map { shape in
                let reason = rule.reason.map { " \($0)" } ?? ""
                return LayoutViolation(
                    kind: .forbiddenLayer,
                    ruleID: forbiddenLayerRuleID(rule),
                    message: "Forbidden marker geometry exists on \(rule.layer.name).\(reason)",
                    layer: rule.layer,
                    region: LayoutGeometryAnalysis.boundingBox(for: shape.geometry),
                    measured: 1,
                    required: 0,
                    unit: "shape",
                    shapeIDs: [shape.id],
                    netIDs: shape.netID.map { [$0] } ?? [],
                    suggestedFix: "Remove or repair the source geometry that produced this forbidden marker."
                )
            }
        }
    }

    func checkWidthAndArea(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        let dbu = tech.units.dbuPerMicron

        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            let merged = mergedRegion(of: layerShapes, dbu: dbu)
            if merged.isEmpty { continue }

            if rules.minWidth > 0 {
                let minWidthDBU = Int32((rules.minWidth * dbu).rounded())
                var reportedRegions: Set<LayoutRect> = []
                for pair in merged.widthViolations(minWidth: minWidthDBU) {
                    let rect = edgePairToRect(pair, dbu: dbu)
                    guard reportedRegions.insert(rect).inserted else { continue }
                    let measured = pair.distance / dbu
                    let contributors = contributingShapes(layerShapes, around: rect)
                    violations.append(LayoutViolation(
                        kind: .minWidth,
                        ruleID: layerRuleID(layer: layer, rule: "minWidth"),
                        message: "Min width violation on \(layer.name). Required \(rules.minWidth)µm, measured \(String(format: "%.3f", measured))µm",
                        layer: layer,
                        region: rect,
                        measured: measured,
                        required: rules.minWidth,
                        unit: "um",
                        shapeIDs: contributors.map(\.id),
                        netIDs: uniqueNetIDs(of: contributors),
                        suggestedFix: "Increase geometry width or update the layer rule if the process allows the measured width."
                    ))
                }
            }

            // Area is checked per connected component of the merged region:
            // abutting shapes form one mask feature, and a merged feature may
            // span multiple stacked polygons.
            if rules.minArea > 0 {
                for component in merged.connectedComponents() {
                    let area = Double(component.area) / (dbu * dbu)
                    guard area > 0, area + Self.numericalTolerance < rules.minArea else { continue }
                    guard let bb = component.boundingBox else { continue }
                    let rect = irBoundingBoxToRect(bb, dbu: dbu)
                    let contributors = contributingShapes(layerShapes, around: rect)
                    violations.append(LayoutViolation(
                        kind: .minArea,
                        ruleID: layerRuleID(layer: layer, rule: "minArea"),
                        message: "Min area violation on \(layer.name). Required \(rules.minArea), got \(area)",
                        layer: layer,
                        region: rect,
                        measured: area,
                        required: rules.minArea,
                        unit: "um2",
                        shapeIDs: contributors.map(\.id),
                        netIDs: uniqueNetIDs(of: contributors),
                        suggestedFix: "Increase the shape area or merge it with connected same-net geometry."
                    ))
                }
            }

            if let minEnclosedArea = rules.minEnclosedArea, minEnclosedArea > 0 {
                for hole in merged.holes() {
                    let area = Double(hole.area) / (dbu * dbu)
                    guard area > 0, area + Self.numericalTolerance < minEnclosedArea else { continue }
                    guard let bb = hole.boundingBox else { continue }
                    let rect = irBoundingBoxToRect(bb, dbu: dbu)
                    let contributors = contributingShapes(layerShapes, around: rect)
                    violations.append(LayoutViolation(
                        kind: .minEnclosedArea,
                        ruleID: layerRuleID(layer: layer, rule: "minEnclosedArea"),
                        message: "Min enclosed area violation on \(layer.name). Required \(minEnclosedArea), got \(area)",
                        layer: layer,
                        region: rect,
                        measured: area,
                        required: minEnclosedArea,
                        unit: "um2",
                        shapeIDs: contributors.map(\.id),
                        netIDs: uniqueNetIDs(of: contributors),
                        suggestedFix: "Enlarge the enclosed opening or close it completely."
                    ))
                }
            }
        }
        return violations
    }

    func checkRectangularGeometry(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        for shape in shapes {
            guard tech.ruleSet(for: shape.layer)?.requiresRectangular == true else { continue }
            guard !isAxisAlignedRectangle(shape.geometry) else { continue }
            violations.append(LayoutViolation(
                kind: .rectOnly,
                ruleID: layerRuleID(layer: shape.layer, rule: "rectOnly"),
                message: "Rect-only violation on \(shape.layer.name). Geometry must be an axis-aligned rectangle.",
                layer: shape.layer,
                region: LayoutGeometryAnalysis.boundingBox(for: shape.geometry),
                shapeIDs: [shape.id],
                netIDs: shape.netID.map { [$0] } ?? [],
                suggestedFix: "Replace this geometry with one or more axis-aligned rectangles on the same layer."
            ))
        }
        return violations
    }

    func checkAngleRules(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        for shape in shapes {
            guard let step = tech.ruleSet(for: shape.layer)?.allowedAngleStepDegrees,
                  step > Self.numericalTolerance,
                  step <= 180 else {
                continue
            }
            guard let violatingEdge = firstAngleViolation(in: shape.geometry, allowedStep: step) else {
                continue
            }
            violations.append(LayoutViolation(
                kind: .angle,
                ruleID: layerRuleID(layer: shape.layer, rule: "angle"),
                message: "Angle violation on \(shape.layer.name). Edge angle \(violatingEdge.angle) degrees is not a multiple of \(step) degrees.",
                layer: shape.layer,
                region: segmentBoundingBox(violatingEdge.segment),
                measured: violatingEdge.angle,
                required: step,
                unit: "degree",
                shapeIDs: [shape.id],
                netIDs: shape.netID.map { [$0] } ?? [],
                suggestedFix: "Adjust the geometry edge to the allowed angle grid for this layer."
            ))
        }
        return violations
    }

    private func isAxisAlignedRectangle(_ geometry: LayoutGeometry) -> Bool {
        switch geometry {
        case .rect(let rect):
            return rect.size.width > Self.numericalTolerance
                && rect.size.height > Self.numericalTolerance
        case .path:
            return false
        case .polygon(let polygon):
            return polygonIsAxisAlignedRectangle(polygon)
        }
    }

    private func polygonIsAxisAlignedRectangle(_ polygon: LayoutPolygon) -> Bool {
        var points: [LayoutPoint] = []
        for point in polygon.points {
            guard points.last.map({ !samePoint($0, point) }) ?? true else { continue }
            points.append(point)
        }
        if let first = points.first, let last = points.last, samePoint(first, last) {
            points.removeLast()
        }
        guard points.count == 4 else { return false }
        let box = LayoutGeometryAnalysis.boundingBox(for: LayoutPolygon(points: points))
        guard box.size.width > Self.numericalTolerance,
              box.size.height > Self.numericalTolerance else {
            return false
        }
        let corners = [
            LayoutPoint(x: box.minX, y: box.minY),
            LayoutPoint(x: box.maxX, y: box.minY),
            LayoutPoint(x: box.maxX, y: box.maxY),
            LayoutPoint(x: box.minX, y: box.maxY),
        ]
        return points.allSatisfy { point in
            corners.contains { samePoint(point, $0) }
        } && corners.allSatisfy { corner in
            points.contains { samePoint($0, corner) }
        }
    }

    private func samePoint(_ lhs: LayoutPoint, _ rhs: LayoutPoint) -> Bool {
        abs(lhs.x - rhs.x) <= Self.numericalTolerance
            && abs(lhs.y - rhs.y) <= Self.numericalTolerance
    }

    private func firstAngleViolation(
        in geometry: LayoutGeometry,
        allowedStep step: Double
    ) -> (segment: LayoutSegment, angle: Double)? {
        for segment in LayoutGeometryAnalysis.segments(for: geometry) {
            let dx = segment.end.x - segment.start.x
            let dy = segment.end.y - segment.start.y
            guard hypot(dx, dy) > Self.numericalTolerance else { continue }
            let angle = normalizedUndirectedAngle(dx: dx, dy: dy)
            guard !isAngleAllowed(angle, step: step) else { continue }
            return (segment, angle)
        }
        return nil
    }

    private func normalizedUndirectedAngle(dx: Double, dy: Double) -> Double {
        var angle = atan2(dy, dx) * 180 / Double.pi
        while angle < 0 {
            angle += 180
        }
        while angle >= 180 {
            angle -= 180
        }
        return angle
    }

    private func isAngleAllowed(_ angle: Double, step: Double) -> Bool {
        let remainder = angle.truncatingRemainder(dividingBy: step)
        return remainder <= Self.numericalTolerance
            || abs(step - remainder) <= Self.numericalTolerance
    }

    private func segmentBoundingBox(_ segment: LayoutSegment) -> LayoutRect {
        let minX = min(segment.start.x, segment.end.x)
        let minY = min(segment.start.y, segment.end.y)
        let maxX = max(segment.start.x, segment.end.x)
        let maxY = max(segment.start.y, segment.end.y)
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    /// Spacing is net-blind on the merged region, matching mask reality:
    /// touching or overlapping shapes never flag (they are one feature), and
    /// any exterior gap narrower than the rule flags regardless of net —
    /// including notches within one feature and diagonal corner gaps.
    func checkSpacing(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        let dbu = tech.units.dbuPerMicron

        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            let hasWideRule = rules.wideWidthThreshold != nil && rules.wideSpacing != nil
            guard rules.minSpacing > 0 || rules.minNotch != nil || hasWideRule else { continue }
            let merged = mergedRegion(of: layerShapes, dbu: dbu)
            if merged.isEmpty { continue }

            if rules.minSpacing > 0 {
                let minSpacingDBU = Int32((rules.minSpacing * dbu).rounded())
                for pair in merged.selfSpaceViolations(minSpace: minSpacingDBU) {
                    let rect = edgePairToRect(pair, dbu: dbu)
                    let measured = pair.distance / dbu
                    let contributors = contributingShapes(layerShapes, around: rect)
                    violations.append(LayoutViolation(
                        kind: .minSpacing,
                        ruleID: layerRuleID(layer: layer, rule: "minSpacing"),
                        message: "Min spacing violation on \(layer.name). Required \(rules.minSpacing)µm, measured \(String(format: "%.3f", measured))µm",
                        layer: layer,
                        region: rect,
                        measured: measured,
                        required: rules.minSpacing,
                        unit: "um",
                        shapeIDs: contributors.map(\.id),
                        netIDs: uniqueNetIDs(of: contributors),
                        suggestedFix: "Move same-layer geometry apart or merge it so the shapes touch; net assignment does not waive spacing."
                    ))
                }
            }

            if let minNotch = rules.minNotch, minNotch > rules.minSpacing {
                let minNotchDBU = Int32((minNotch * dbu).rounded())
                let components = merged.connectedComponents()
                for pair in merged.selfSpaceViolations(minSpace: minNotchDBU) {
                    let measured = pair.distance / dbu
                    // Gaps below minSpacing are already reported by the base rule.
                    guard measured + Self.numericalTolerance >= rules.minSpacing else { continue }
                    guard edgesBelongToSameComponent(pair, components: components) else { continue }
                    let rect = edgePairToRect(pair, dbu: dbu)
                    let contributors = contributingShapes(layerShapes, around: rect)
                    violations.append(LayoutViolation(
                        kind: .notch,
                        ruleID: layerRuleID(layer: layer, rule: "minNotch"),
                        message: "Notch violation on \(layer.name). Required \(minNotch)µm, measured \(String(format: "%.3f", measured))µm",
                        layer: layer,
                        region: rect,
                        measured: measured,
                        required: minNotch,
                        unit: "um",
                        shapeIDs: contributors.map(\.id),
                        netIDs: uniqueNetIDs(of: contributors),
                        suggestedFix: "Widen the notch opening or fill it completely."
                    ))
                }
            }

            if let wideWidth = rules.wideWidthThreshold,
               let wideSpacing = rules.wideSpacing,
               wideWidth > 0, wideSpacing > rules.minSpacing {
                let halfWidthDBU = Int32(((wideWidth / 2) * dbu).rounded())
                let wide = merged.sized(by: -halfWidthDBU).sized(by: halfWidthDBU)
                if !wide.isEmpty {
                    let wideSpacingDBU = Int32((wideSpacing * dbu).rounded())
                    for pair in wide.spaceViolations(to: merged, minSpace: wideSpacingDBU) {
                        let measured = pair.distance / dbu
                        // Gaps below minSpacing are already reported by the base rule.
                        guard measured + Self.numericalTolerance >= rules.minSpacing else { continue }
                        let rect = edgePairToRect(pair, dbu: dbu)
                        let contributors = contributingShapes(layerShapes, around: rect)
                        violations.append(LayoutViolation(
                            kind: .minSpacing,
                            ruleID: layerRuleID(layer: layer, rule: "wideSpacing"),
                            message: "Wide-metal spacing violation on \(layer.name). Required \(wideSpacing)µm next to metal wider than \(wideWidth)µm, measured \(String(format: "%.3f", measured))µm",
                            layer: layer,
                            region: rect,
                            measured: measured,
                            required: wideSpacing,
                            unit: "um",
                            shapeIDs: contributors.map(\.id),
                            netIDs: uniqueNetIDs(of: contributors),
                            suggestedFix: "Increase clearance around wide metal or narrow the wide feature."
                        ))
                    }
                }
            }
        }
        return violations
    }

    func checkSpacingRules(
        shapes: [LayoutShape],
        tech: LayoutTechDatabase,
        rules: [LayoutSpacingRule]? = nil
    ) -> [LayoutViolation] {
        let spacingRules = rules ?? tech.spacingRules
        guard !spacingRules.isEmpty else { return [] }
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        let dbu = tech.units.dbuPerMicron
        var violations: [LayoutViolation] = []

        for rule in spacingRules {
            guard rule.primaryLayer != rule.secondaryLayer,
                  rule.minSpacing > 0 else {
                continue
            }
            guard let primaryShapes = grouped[rule.primaryLayer], !primaryShapes.isEmpty,
                  let secondaryShapes = grouped[rule.secondaryLayer], !secondaryShapes.isEmpty else {
                continue
            }
            let primary = mergedRegion(of: primaryShapes, dbu: dbu)
            let secondary = mergedRegion(of: secondaryShapes, dbu: dbu)
            if primary.isEmpty || secondary.isEmpty { continue }

            let minSpacingDBU = Int32((rule.minSpacing * dbu).rounded())
            for pair in primary.spaceViolations(to: secondary, minSpace: minSpacingDBU) {
                let rect = edgePairToRect(pair, dbu: dbu)
                let measured = pair.distance / dbu
                let contributors = contributingShapes(primaryShapes + secondaryShapes, around: rect)
                violations.append(LayoutViolation(
                    kind: .minSpacing,
                    ruleID: spacingRuleID(rule),
                    message: "Layer spacing violation between \(rule.primaryLayer.name) and \(rule.secondaryLayer.name). Required \(rule.minSpacing)µm, measured \(String(format: "%.3f", measured))µm",
                    layer: rule.primaryLayer,
                    region: rect,
                    measured: measured,
                    required: rule.minSpacing,
                    unit: "um",
                    shapeIDs: contributors.map(\.id),
                    netIDs: uniqueNetIDs(of: contributors),
                    suggestedFix: "Increase clearance between \(rule.primaryLayer.name) and \(rule.secondaryLayer.name) geometry."
                ))
            }
        }
        return violations
    }

    private func edgesBelongToSameComponent(_ pair: IREdgePair, components: [Region]) -> Bool {
        let first = midpoint(of: pair.edge1)
        let second = midpoint(of: pair.edge2)
        return components.contains { $0.contains(first) && $0.contains(second) }
    }

    private func midpoint(of edge: IREdge) -> IRPoint {
        IRPoint(
            x: Int32((Int64(edge.p1.x) + Int64(edge.p2.x)) / 2),
            y: Int32((Int64(edge.p1.y) + Int64(edge.p2.y)) / 2)
        )
    }



    /// `layerFilter` restricts which layers are evaluated; the density
    /// windows are always derived from the bounding box of ALL passed
    /// shapes, so callers must pass the full flattened shape set.
    func checkDensity(
        shapes: [LayoutShape],
        tech: LayoutTechDatabase,
        layerFilter: Set<LayoutLayerID>? = nil
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        guard let overall = overallBoundingBox(shapes: shapes) else { return violations }

        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        for (layer, layerShapes) in grouped {
            if let layerFilter, !layerFilter.contains(layer) { continue }
            guard let rules = tech.ruleSet(for: layer) else { continue }
            let windows = densityWindows(for: overall, rules: rules)
            for window in windows {
                let area = mergedClippedArea(
                    of: layerShapes, in: window, dbu: tech.units.dbuPerMicron
                )
                if let violation = densityViolation(
                    layerShapes: layerShapes, layer: layer, rules: rules, window: window, area: area
                ) {
                    violations.append(violation)
                }
            }
        }
        return violations
    }

    /// Emits the density verdict for one window given the precomputed clipped
    /// area. The area must be the boolean-merged (union) clipped area from
    /// `mergedClippedArea` — overlapping geometry counts once, so the
    /// measured density can never exceed 1.0 — and the integer dbu-space
    /// union is order-independent, so incremental callers reproduce the
    /// full-run value exactly.
    func densityViolation(
        layerShapes: [LayoutShape],
        layer: LayoutLayerID,
        rules: LayoutLayerRuleSet,
        window: LayoutRect,
        area: Double
    ) -> LayoutViolation? {
        let windowArea = window.size.width * window.size.height
        guard windowArea > 0 else { return nil }
        let density = area / windowArea
        guard density < rules.minDensity || density > rules.maxDensity else { return nil }
        return LayoutViolation(
            kind: .density,
            ruleID: layerRuleID(layer: layer, rule: density < rules.minDensity ? "minDensity" : "maxDensity"),
            severity: .warning,
            message: "Density violation on \(layer.name). Range \(rules.minDensity)-\(rules.maxDensity), got \(density)",
            layer: layer,
            region: window,
            measured: density,
            required: density < rules.minDensity ? rules.minDensity : rules.maxDensity,
            unit: "ratio",
            shapeIDs: layerShapes.map(\.id),
            suggestedFix: density < rules.minDensity ? "Add fill or enlarge layer coverage in the checked window." : "Remove excess fill or reduce layer coverage in the checked window."
        )
    }


    /// Pair verdict for the same-layer short check; `first` must precede
    /// `second` in flattened order so the violation payload matches the
    /// full-scan emission exactly.



    /// Single source of truth for "do these two flattened elements touch
    /// electrically": shape–shape requires the same layer plus geometric
    /// intersection, via–via never connects directly, and via–shape
    /// requires the shape to sit on the via's top or bottom layer and
    /// intersect the cut rectangle. The open check and the connectivity
    /// extractor both call this so their notions of contact can never
    /// diverge.

    /// Staged antenna model: for each antenna-rule layer in fabrication
    /// order (derived from the via/contact bottom→top relations), build the
    /// conductor connectivity that physically exists while that layer is
    /// being etched — conductors of equal or lower rank plus cuts whose top
    /// layer has been deposited — and evaluate every connected component
    /// that reaches gate pins but no diffusion discharge path (a
    /// source/drain/bulk-role pin).
    ///
    /// Gate area is the summed area of the connected gate-role pins; charge
    /// collection per layer uses boolean-merged areas so overlapping wires
    /// and landing pads are not double-counted. PAR compares the rule
    /// layer's merged area against `maxRatio`; CAR additionally sums every
    /// antenna-rule layer fabricated so far against `maxCumulativeRatio`.
    /// Configuration gaps (underivable stack, rules or gate pins outside
    /// the stack, unknown via definitions) are reported as violations
    /// instead of being skipped.


    /// Boolean-merged area in square microns; overlapping shapes count once.

    /// Layer-pair enclosure is checked per connected inner component, and only
    /// where the inner component interacts with the outer layer: features that
    /// never touch the outer layer are outside the rule's scope (e.g. NMOS
    /// active against NWELL). Interacting components must be fully covered with
    /// the required margin unless the rule allows pass-through, in which case
    /// only the covered portion is constrained and the crossing is masked.
    /// `rules` restricts which enclosure rules are evaluated (nil checks
    /// every rule in the technology database); each rule's verdict depends
    /// only on the geometry of its own outer and inner layers.

    /// Thickness of a margin-deficit region: the deficit hugs the outer
    /// boundary as bands, so the smallest bounding-box dimension over its
    /// polygons is the missing margin. The component bounding box would
    /// overestimate ring-shaped deficits.







    /// `candidates` must contain every same-layer shape whose bounding box
    /// intersects the cut rect expanded by `enclosure` (callers pass spatial
    /// index results); shapes farther away cannot affect the verdict.












    func densityWindows(for overall: LayoutRect, rules: LayoutLayerRuleSet) -> [LayoutRect] {
        guard let windowSize = rules.densityWindow,
              windowSize.width > 0,
              windowSize.height > 0 else {
            return [overall]
        }
        let step = rules.densityStep ?? min(windowSize.width, windowSize.height)
        let xStarts = densityWindowStarts(min: overall.minX, max: overall.maxX, window: windowSize.width, step: step)
        let yStarts = densityWindowStarts(min: overall.minY, max: overall.maxY, window: windowSize.height, step: step)
        var windows: [LayoutRect] = []
        for x in xStarts {
            for y in yStarts {
                windows.append(LayoutRect(origin: LayoutPoint(x: x, y: y), size: windowSize))
            }
        }
        return windows
    }

    private func densityWindowStarts(min: Double, max: Double, window: Double, step: Double) -> [Double] {
        guard step > 0 else { return [min] }
        let lastStart = max - window
        if lastStart <= min {
            return [min]
        }
        var starts: [Double] = []
        var current = min
        while current <= lastStart + 1e-12 {
            starts.append(current)
            current += step
        }
        if let last = starts.last, abs(last - lastStart) > 1e-12 {
            starts.append(lastStart)
        }
        return starts
    }

    /// Boolean-merged (union) area of the shapes inside the window, in um².
    ///
    /// Shapes whose slack-expanded bounding box misses the window are
    /// skipped — dbu rounding can move an edge by up to half a dbu, so the
    /// one-dbu slack guarantees the prefilter never drops a contributing
    /// shape. The union area of a point set is canonical, so the result is
    /// independent of shape order and of which zero-contribution shapes
    /// are passed; the incremental session relies on this to reproduce the
    /// full run exactly.
    func mergedClippedArea(of shapes: [LayoutShape], in window: LayoutRect, dbu: Double) -> Double {
        let slack = 1.0 / dbu
        var boundaries: [IRBoundary] = []
        for shape in shapes {
            let bbox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            guard bbox.expanded(by: slack, slack).intersects(window) else { continue }
            if let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu) {
                boundaries.append(boundary)
            }
        }
        guard !boundaries.isEmpty else { return 0 }
        // OR with the empty region normalizes overlapping input polygons
        // into disjoint ones; the AND of disjoint polygons with the window
        // is disjoint, so the shoelace `area` is the exact union area.
        let merged = Region(polygons: boundaries).or(Region())
        let clipped = merged.and(rectToRegion(window, dbu: dbu))
        return abs(Double(clipped.area)) / (dbu * dbu)
    }

    private func layerRuleID(layer: LayoutLayerID, rule: String) -> String {
        "layer.\(layer.name).\(layer.purpose).\(rule)"
    }

    func enclosureRuleID(_ rule: LayoutEnclosureRule) -> String {
        "enclosure.\(rule.outerLayer.name).\(rule.outerLayer.purpose).\(rule.innerLayer.name).\(rule.innerLayer.purpose)"
    }

    func spacingRuleID(_ rule: LayoutSpacingRule) -> String {
        "spacing.\(rule.primaryLayer.name).\(rule.primaryLayer.purpose).\(rule.secondaryLayer.name).\(rule.secondaryLayer.purpose).\(rule.id)"
    }

    func extensionRuleID(_ rule: LayoutExtensionRule) -> String {
        "extension.\(rule.extendingLayer.name).\(rule.extendingLayer.purpose).\(rule.enclosedLayer.name).\(rule.enclosedLayer.purpose).\(rule.direction.rawValue)"
    }

    func minimumCutRuleID(_ rule: LayoutMinimumCutRule) -> String {
        "minimumCut.\(rule.cutLayer.name).\(rule.cutLayer.purpose).\(rule.bottomLayer.name).\(rule.bottomLayer.purpose).\(rule.topLayer.name).\(rule.topLayer.purpose).\(rule.id)"
    }

    func exactOverlapRuleID(_ rule: LayoutExactOverlapRule) -> String {
        let secondaryID = rule.secondaryLayers.count == 1
            ? "\(rule.secondaryLayer.name).\(rule.secondaryLayer.purpose)"
            : "oneOf." + rule.secondaryLayers.map { "\($0.name).\($0.purpose)" }.joined(separator: ".")
        return "exactOverlap.\(rule.primaryLayer.name).\(rule.primaryLayer.purpose).\(secondaryID).\(rule.id)"
    }

    func forbiddenLayerRuleID(_ rule: LayoutForbiddenLayerRule) -> String {
        "forbiddenLayer.\(rule.layer.name).\(rule.layer.purpose).\(rule.id)"
    }

    func antennaRuleID(_ rule: LayoutAntennaRule) -> String {
        "antenna.\(rule.layerID.name).\(rule.layerID.purpose).maxRatio"
    }

    func cumulativeAntennaRuleID(_ rule: LayoutAntennaRule) -> String {
        "antenna.\(rule.layerID.name).\(rule.layerID.purpose).maxCumulativeRatio"
    }

    // MARK: - MaskGeometry Bridge

    /// Boolean-merged region of the shapes: abutting and overlapping shapes
    /// become single features, matching what lands on the mask.
    func mergedRegion(of shapes: [LayoutShape], dbu: Double) -> Region {
        let region = shapesToRegion(shapes, dbu: dbu)
        return region.or(Region(layer: region.layer))
    }

    /// Shapes whose bounding box touches the violation marker, in document
    /// order — the evidence trail for a merged-geometry violation.
    func contributingShapes(_ shapes: [LayoutShape], around rect: LayoutRect) -> [LayoutShape] {
        shapes.filter { LayoutGeometryAnalysis.boundingBox(for: $0.geometry).intersects(rect) }
    }

    func uniqueNetIDs(of shapes: [LayoutShape]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for shape in shapes {
            guard let netID = shape.netID, seen.insert(netID).inserted else { continue }
            result.append(netID)
        }
        return result
    }

    func irBoundingBoxToRect(
        _ bb: (minX: Int32, minY: Int32, maxX: Int32, maxY: Int32),
        dbu: Double
    ) -> LayoutRect {
        let minX = Double(bb.minX) / dbu
        let minY = Double(bb.minY) / dbu
        let maxX = Double(bb.maxX) / dbu
        let maxY = Double(bb.maxY) / dbu
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
        )
    }

    func shapesToRegion(_ shapes: [LayoutShape], dbu: Double) -> Region {
        var boundaries: [IRBoundary] = []
        for shape in shapes {
            if let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu) {
                boundaries.append(boundary)
            }
        }
        return Region(polygons: boundaries)
    }

    func rectToRegion(_ rect: LayoutRect, dbu: Double) -> Region {
        if let boundary = geometryToIRBoundary(.rect(rect), dbu: dbu) {
            return Region(polygons: [boundary])
        }
        return Region()
    }

    func geometryToIRBoundary(_ geometry: LayoutGeometry, dbu: Double) -> IRBoundary? {
        switch geometry {
        case .rect(let rect):
            let minX = Int32((rect.minX * dbu).rounded())
            let minY = Int32((rect.minY * dbu).rounded())
            let maxX = Int32((rect.maxX * dbu).rounded())
            let maxY = Int32((rect.maxY * dbu).rounded())
            return IRBoundary(layer: 0, datatype: 0, points: [
                IRPoint(x: minX, y: minY), IRPoint(x: maxX, y: minY),
                IRPoint(x: maxX, y: maxY), IRPoint(x: minX, y: maxY),
                IRPoint(x: minX, y: minY),
            ])
        case .polygon(let poly):
            guard poly.points.count >= 3 else { return nil }
            var points = poly.points.map { micronPointToIR($0, dbu: dbu) }
            if points.first != points.last { points.append(points[0]) }
            return IRBoundary(layer: 0, datatype: 0, points: points)
        case .path(let path):
            return pathToIRBoundary(path, dbu: dbu)
        }
    }

    private func micronPointToIR(_ p: LayoutPoint, dbu: Double) -> IRPoint {
        IRPoint(x: Int32((p.x * dbu).rounded()), y: Int32((p.y * dbu).rounded()))
    }

    private func pathToIRBoundary(_ path: LayoutPath, dbu: Double) -> IRBoundary? {
        guard path.points.count >= 2, path.width > 0 else { return nil }
        let halfW = path.width / 2.0

        if path.points.count == 2 {
            let p0 = path.points[0]
            let p1 = path.points[1]
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { return nil }
            let nx = -dy / len * halfW
            let ny = dx / len * halfW
            let ext: Double = path.endCap == .extend ? halfW : 0
            let ex = dx / len * ext
            let ey = dy / len * ext

            var pts = [
                micronPointToIR(LayoutPoint(x: p0.x - ex + nx, y: p0.y - ey + ny), dbu: dbu),
                micronPointToIR(LayoutPoint(x: p1.x + ex + nx, y: p1.y + ey + ny), dbu: dbu),
                micronPointToIR(LayoutPoint(x: p1.x + ex - nx, y: p1.y + ey - ny), dbu: dbu),
                micronPointToIR(LayoutPoint(x: p0.x - ex - nx, y: p0.y - ey - ny), dbu: dbu),
            ]
            pts.append(pts[0])
            return IRBoundary(layer: 0, datatype: 0, points: pts)
        }

        var leftPoints: [IRPoint] = []
        var rightPoints: [IRPoint] = []

        for i in 0..<path.points.count {
            let curr = path.points[i]
            var nx = 0.0, ny = 0.0
            var count = 0.0

            if i > 0 {
                let prev = path.points[i - 1]
                let sdx = curr.x - prev.x, sdy = curr.y - prev.y
                let slen = (sdx * sdx + sdy * sdy).squareRoot()
                if slen > 0 { nx += -sdy / slen; ny += sdx / slen; count += 1 }
            }
            if i < path.points.count - 1 {
                let next = path.points[i + 1]
                let sdx = next.x - curr.x, sdy = next.y - curr.y
                let slen = (sdx * sdx + sdy * sdy).squareRoot()
                if slen > 0 { nx += -sdy / slen; ny += sdx / slen; count += 1 }
            }
            guard count > 0 else { continue }
            nx /= count; ny /= count
            let nlen = (nx * nx + ny * ny).squareRoot()
            guard nlen > 0 else { continue }
            nx /= nlen; ny /= nlen

            leftPoints.append(micronPointToIR(LayoutPoint(x: curr.x + nx * halfW, y: curr.y + ny * halfW), dbu: dbu))
            rightPoints.append(micronPointToIR(LayoutPoint(x: curr.x - nx * halfW, y: curr.y - ny * halfW), dbu: dbu))
        }

        var pts = leftPoints + rightPoints.reversed()
        guard pts.count >= 3 else { return nil }
        pts.append(pts[0])
        return IRBoundary(layer: 0, datatype: 0, points: pts)
    }

    private func edgePairToRect(_ pair: IREdgePair, dbu: Double) -> LayoutRect {
        let minXValue = min(min(pair.edge1.p1.x, pair.edge1.p2.x), min(pair.edge2.p1.x, pair.edge2.p2.x))
        let minYValue = min(min(pair.edge1.p1.y, pair.edge1.p2.y), min(pair.edge2.p1.y, pair.edge2.p2.y))
        let maxXValue = max(max(pair.edge1.p1.x, pair.edge1.p2.x), max(pair.edge2.p1.x, pair.edge2.p2.x))
        let maxYValue = max(max(pair.edge1.p1.y, pair.edge1.p2.y), max(pair.edge2.p1.y, pair.edge2.p2.y))
        let minX = Double(minXValue) / dbu
        let minY = Double(minYValue) / dbu
        let maxX = Double(maxXValue) / dbu
        let maxY = Double(maxYValue) / dbu
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
        )
    }

    func overallBoundingBox(shapes: [LayoutShape]) -> LayoutRect? {
        let boxes = shapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        return overallBoundingBox(rects: boxes)
    }

    func overallBoundingBox(geometries: [LayoutGeometry]) -> LayoutRect? {
        let boxes = geometries.map { LayoutGeometryAnalysis.boundingBox(for: $0) }
        return overallBoundingBox(rects: boxes)
    }

    private func overallBoundingBox(rects: [LayoutRect]) -> LayoutRect? {
        guard var current = rects.first else { return nil }
        for rect in rects.dropFirst() {
            current = current.union(rect)
        }
        return current
    }
}

private struct LayoutDRCRunContext: Sendable {
    var shapes: [LayoutShape]
    var vias: [LayoutVia]
    var pins: [LayoutPin]
    var terminalConflicts: [LayoutDRCService.TerminalConnectivityConflict]
}
