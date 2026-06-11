import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

public struct LayoutDRCService {
    private static let numericalTolerance = 1.0e-12

    public init() {}

    public func run(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) -> LayoutDRCResult {
        guard let targetCell = resolveCell(document: document, cellID: cellID) else {
            return LayoutDRCResult(violations: [])
        }

        var flattenedShapes: [LayoutShape] = []
        var flattenedVias: [LayoutVia] = []
        var flattenedPins: [LayoutPin] = []
        var terminalConflicts: [TerminalConnectivityConflict] = []
        flatten(
            cell: targetCell,
            document: document,
            tech: tech,
            transforms: [],
            terminalNetIDs: [:],
            shapes: &flattenedShapes,
            vias: &flattenedVias,
            pins: &flattenedPins,
            terminalConflicts: &terminalConflicts
        )

        var violations: [LayoutViolation] = []

        violations.append(contentsOf: terminalConflicts.map(makeTerminalConflictViolation))
        violations.append(contentsOf: checkRuleCoverage(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkWidthAndArea(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkSpacing(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkViaEnclosure(shapes: flattenedShapes, vias: flattenedVias, tech: tech))
        violations.append(contentsOf: checkEnclosureRules(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkDensity(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkShorts(shapes: flattenedShapes))
        violations.append(contentsOf: checkOpens(shapes: flattenedShapes, vias: flattenedVias, tech: tech))
        violations.append(contentsOf: checkAntenna(
            shapes: flattenedShapes,
            vias: flattenedVias,
            pins: flattenedPins,
            tech: tech
        ))

        return LayoutDRCResult(violations: violations)
    }

    func resolveCell(document: LayoutDocument, cellID: UUID?) -> LayoutCell? {
        if let id = cellID {
            return document.cell(withID: id)
        }
        if let topID = document.topCellID {
            return document.cell(withID: topID)
        }
        return document.cells.first
    }

    func flatten(
        cell: LayoutCell,
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        transforms: [LayoutTransform],
        terminalNetIDs: [String: UUID],
        shapes: inout [LayoutShape],
        vias: inout [LayoutVia],
        pins: inout [LayoutPin],
        terminalConflicts: inout [TerminalConnectivityConflict]
    ) {
        let terminalConnectivity = terminalConnectivity(cell: cell, terminalNetIDs: terminalNetIDs, tech: tech)
        terminalConflicts.append(contentsOf: terminalConnectivity.conflicts.map {
            $0.transformed(by: transforms)
        })

        for shape in cell.shapes {
            var transformed = shape
            if transformed.netID == nil {
                transformed.netID = terminalConnectivity.shapeNetIDs[shape.id]
            }
            transformed.geometry = applyTransforms(to: shape.geometry, transforms: transforms)
            shapes.append(transformed)
        }

        for via in cell.vias {
            var transformed = via
            if transformed.netID == nil {
                transformed.netID = terminalConnectivity.viaNetIDs[via.id]
            }
            transformed.position = applyTransforms(to: via.position, transforms: transforms)
            vias.append(transformed)
        }

        for pin in cell.pins {
            var transformed = pin
            if transformed.netID == nil {
                transformed.netID = terminalNetIDs[pin.name]
            }
            transformed.position = applyTransforms(to: pin.position, transforms: transforms)
            pins.append(transformed)
        }

        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            flatten(
                cell: child,
                document: document,
                tech: tech,
                transforms: transforms + [instance.transform],
                terminalNetIDs: instance.terminalNetIDs,
                shapes: &shapes,
                vias: &vias,
                pins: &pins,
                terminalConflicts: &terminalConflicts
            )
        }
    }

    private struct TerminalConnectivity: Sendable {
        var shapeNetIDs: [UUID: UUID]
        var viaNetIDs: [UUID: UUID]
        var conflicts: [TerminalConnectivityConflict]
    }

    struct TerminalConnectivityConflict: Sendable {
        var netIDs: [UUID]
        var shapeIDs: [UUID]
        var viaIDs: [UUID]
        var pinIDs: [UUID]
        var region: LayoutRect

        func transformed(by transforms: [LayoutTransform]) -> TerminalConnectivityConflict {
            TerminalConnectivityConflict(
                netIDs: netIDs,
                shapeIDs: shapeIDs,
                viaIDs: viaIDs,
                pinIDs: pinIDs,
                region: applyTransforms(to: region, transforms: transforms)
            )
        }

        private func applyTransforms(to rect: LayoutRect, transforms: [LayoutTransform]) -> LayoutRect {
            let geometry = LayoutGeometry.rect(rect)
            var current = geometry
            for transform in transforms.reversed() {
                current = current.transformed(by: transform)
            }
            return LayoutGeometryAnalysis.boundingBox(for: current)
        }
    }

    private func terminalConnectivity(
        cell: LayoutCell,
        terminalNetIDs: [String: UUID],
        tech: LayoutTechDatabase
    ) -> TerminalConnectivity {
        guard !terminalNetIDs.isEmpty else {
            return TerminalConnectivity(shapeNetIDs: [:], viaNetIDs: [:], conflicts: [])
        }

        var geometries: [LayoutGeometry] = []
        var layers: [LayoutLayerID?] = []
        var isVia: [Bool] = []
        var viaDefs: [LayoutViaDefinition?] = []
        var shapeIDsByNode: [Int: UUID] = [:]
        var viaIDsByNode: [Int: UUID] = [:]

        for shape in cell.shapes {
            let index = geometries.count
            geometries.append(shape.geometry)
            layers.append(shape.layer)
            isVia.append(false)
            viaDefs.append(nil)
            shapeIDsByNode[index] = shape.id
        }

        for via in cell.vias {
            let index = geometries.count
            geometries.append(.rect(viaCutRect(for: via, tech: tech)))
            layers.append(nil)
            isVia.append(true)
            viaDefs.append(tech.viaDefinition(for: via.viaDefinitionID))
            viaIDsByNode[index] = via.id
        }

        guard !geometries.isEmpty else {
            return TerminalConnectivity(shapeNetIDs: [:], viaNetIDs: [:], conflicts: [])
        }

        // Connectivity and pin contact both require geometric intersection,
        // so one spatial index serves the pair scan and the pin probes; the
        // union-find result is independent of pair visiting order.
        let boxes = geometries.map { LayoutGeometryAnalysis.boundingBox(for: $0) }
        let grid = ShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
        )
        var unionFind = LayoutUnionFind(count: geometries.count)
        if geometries.count > 1 {
            for i in 0..<(geometries.count - 1) {
                for j in grid.candidateIndices(near: boxes[i]) where j > i {
                    guard unionFind.find(i) != unionFind.find(j) else { continue }
                    if shouldConnect(
                        indexA: i,
                        indexB: j,
                        geometries: geometries,
                        layers: layers,
                        isVia: isVia,
                        viaDefs: viaDefs
                    ) {
                        unionFind.union(i, j)
                    }
                }
            }
        }

        var netIDsByRoot: [Int: Set<UUID>] = [:]
        var pinIDsByRoot: [Int: Set<UUID>] = [:]

        for pin in cell.pins {
            guard let netID = terminalNetIDs[pin.name] else { continue }
            let pinRect = LayoutRect(
                origin: LayoutPoint(
                    x: pin.position.x - pin.size.width / 2,
                    y: pin.position.y - pin.size.height / 2
                ),
                size: pin.size
            )

            for index in grid.candidateIndices(near: pinRect) {
                guard terminalContactIntersects(
                    pinRect: pinRect,
                    pin: pin,
                    geometry: geometries[index],
                    layer: layers[index],
                    isVia: isVia[index],
                    viaDefinition: viaDefs[index]
                ) else {
                    continue
                }
                let root = unionFind.find(index)
                netIDsByRoot[root, default: []].insert(netID)
                pinIDsByRoot[root, default: []].insert(pin.id)
            }
        }

        let componentNodes = unionFind.components()
        var shapeNetIDs: [UUID: UUID] = [:]
        var viaNetIDs: [UUID: UUID] = [:]
        var conflicts: [TerminalConnectivityConflict] = []

        for (root, netIDs) in netIDsByRoot {
            let nodes = componentNodes[root] ?? []
            if netIDs.count == 1, let netID = netIDs.first {
                for node in nodes {
                    if let shapeID = shapeIDsByNode[node] {
                        shapeNetIDs[shapeID] = netID
                    }
                    if let viaID = viaIDsByNode[node] {
                        viaNetIDs[viaID] = netID
                    }
                }
            } else {
                conflicts.append(TerminalConnectivityConflict(
                    netIDs: netIDs.sorted { $0.uuidString < $1.uuidString },
                    shapeIDs: nodes.compactMap { shapeIDsByNode[$0] },
                    viaIDs: nodes.compactMap { viaIDsByNode[$0] },
                    pinIDs: Array(pinIDsByRoot[root, default: []]).sorted { $0.uuidString < $1.uuidString },
                    region: overallBoundingBox(geometries: nodes.map { geometries[$0] }) ?? .zero
                ))
            }
        }

        return TerminalConnectivity(shapeNetIDs: shapeNetIDs, viaNetIDs: viaNetIDs, conflicts: conflicts)
    }

    private func terminalContactIntersects(
        pinRect: LayoutRect,
        pin: LayoutPin,
        geometry: LayoutGeometry,
        layer: LayoutLayerID?,
        isVia: Bool,
        viaDefinition: LayoutViaDefinition?
    ) -> Bool {
        if isVia {
            guard let viaDefinition else { return false }
            guard pin.layer == viaDefinition.topLayer || pin.layer == viaDefinition.bottomLayer else {
                return false
            }
        } else {
            guard layer == pin.layer else { return false }
        }

        let geometryBox = LayoutGeometryAnalysis.boundingBox(for: geometry)
        return geometryBox.intersects(pinRect)
            || LayoutGeometryAnalysis.contains(pin.position, in: geometry)
            || LayoutGeometryAnalysis.intersects(geometry, .rect(pinRect))
    }

    func makeTerminalConflictViolation(_ conflict: TerminalConnectivityConflict) -> LayoutViolation {
        LayoutViolation(
            kind: .overlapShort,
            ruleID: "connectivity.short.terminalComponent",
            message: "Short between terminal nets in one connected component",
            region: conflict.region,
            shapeIDs: conflict.shapeIDs,
            viaIDs: conflict.viaIDs,
            pinIDs: conflict.pinIDs,
            netIDs: conflict.netIDs,
            suggestedFix: "Separate the connected geometry or map the instance terminals to the same net intentionally."
        )
    }

    private func applyTransforms(to point: LayoutPoint, transforms: [LayoutTransform]) -> LayoutPoint {
        var current = point
        for transform in transforms.reversed() {
            current = transform.apply(to: current)
        }
        return current
    }

    private func applyTransforms(to geometry: LayoutGeometry, transforms: [LayoutTransform]) -> LayoutGeometry {
        var current = geometry
        for transform in transforms.reversed() {
            current = current.transformed(by: transform)
        }
        return current
    }

    func checkRuleCoverage(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        return grouped.compactMap { layer, layerShapes in
            guard tech.ruleSet(for: layer) == nil else { return nil }
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
            let cutRect = LayoutRect(
                origin: LayoutPoint(
                    x: via.position.x - def.cutSize.width / 2,
                    y: via.position.y - def.cutSize.height / 2
                ),
                size: def.cutSize
            )

            let topCheck = viaEnclosureCheck(
                cutRect: cutRect,
                enclosure: def.enclosure.top,
                candidates: candidates(
                    layer: def.topLayer,
                    nearHalo: cutRect.expanded(by: def.enclosure.top, def.enclosure.top)
                ),
                dbu: dbu
            )
            let bottomCheck = viaEnclosureCheck(
                cutRect: cutRect,
                enclosure: def.enclosure.bottom,
                candidates: candidates(
                    layer: def.bottomLayer,
                    nearHalo: cutRect.expanded(by: def.enclosure.bottom, def.enclosure.bottom)
                ),
                dbu: dbu
            )

            if !topCheck.passed || !bottomCheck.passed {
                let missing = [
                    topCheck.passed ? nil : "top \(def.topLayer.name)",
                    bottomCheck.passed ? nil : "bottom \(def.bottomLayer.name)"
                ].compactMap { $0 }.joined(separator: ", ")
                violations.append(LayoutViolation(
                    kind: .enclosure,
                    ruleID: "via.\(via.viaDefinitionID).enclosure",
                    message: "Via enclosure violation for \(via.viaDefinitionID): missing \(missing)",
                    layer: def.cutLayer,
                    region: cutRect,
                    measured: min(topCheck.measured, bottomCheck.measured),
                    required: max(def.enclosure.top, def.enclosure.bottom),
                    unit: "um",
                    viaIDs: [via.id],
                    netIDs: [via.netID].compactMap { $0 },
                    suggestedFix: "Add top and bottom metal coverage around the via cut."
                ))
            }
        }
        return violations
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

    func checkShorts(shapes: [LayoutShape]) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        if shapes.count < 2 { return violations }

        // A short requires geometric intersection, so a per-layer spatial
        // index prunes the pair scan to bbox neighbours. Per-layer index
        // arrays are ascending, so candidate order matches the original
        // global (i, j) scan and the emission order is preserved.
        let boxes = shapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        var indicesByLayer: [LayoutLayerID: [Int]] = [:]
        for (index, shape) in shapes.enumerated() {
            indicesByLayer[shape.layer, default: []].append(index)
        }
        var gridsByLayer: [LayoutLayerID: ShapeGridIndex] = [:]
        for (layer, indices) in indicesByLayer {
            let layerBoxes = indices.map { boxes[$0] }
            gridsByLayer[layer] = ShapeGridIndex(
                boundingBoxes: layerBoxes,
                cellSize: ShapeGridIndex.defaultCellSize(for: layerBoxes)
            )
        }

        for i in 0..<(shapes.count - 1) {
            let a = shapes[i]
            guard let grid = gridsByLayer[a.layer],
                  let layerIndices = indicesByLayer[a.layer] else { continue }
            for localIndex in grid.candidateIndices(near: boxes[i]) {
                let j = layerIndices[localIndex]
                guard j > i else { continue }
                let b = shapes[j]
                if let violation = sameLayerShortViolation(first: a, second: b) {
                    violations.append(violation)
                }
            }
        }
        return violations
    }

    /// Pair verdict for the same-layer short check; `first` must precede
    /// `second` in flattened order so the violation payload matches the
    /// full-scan emission exactly.
    func sameLayerShortViolation(first: LayoutShape, second: LayoutShape) -> LayoutViolation? {
        guard first.layer == second.layer else { return nil }
        guard let na = first.netID, let nb = second.netID, na != nb else { return nil }
        guard LayoutGeometryAnalysis.intersects(first.geometry, second.geometry) else { return nil }
        let region = LayoutGeometryAnalysis.boundingBox(for: first.geometry).union(
            LayoutGeometryAnalysis.boundingBox(for: second.geometry)
        )
        return LayoutViolation(
            kind: .overlapShort,
            ruleID: "connectivity.short.sameLayerOverlap",
            message: "Short between shapes on different nets",
            layer: first.layer,
            region: region,
            shapeIDs: [first.id, second.id],
            netIDs: [na, nb],
            suggestedFix: "Separate the shapes or intentionally assign them to the same net before verification."
        )
    }

    func checkOpens(shapes: [LayoutShape], vias: [LayoutVia], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let netShapes = shapes.filter { $0.netID != nil }
        if netShapes.isEmpty { return violations }

        let nets = Dictionary(grouping: netShapes, by: { $0.netID! })
        let viasByNet = Dictionary(grouping: vias.filter { $0.netID != nil }, by: { $0.netID! })
        for (netID, shapesForNet) in nets {
            var geometries: [LayoutGeometry] = []
            var layers: [LayoutLayerID?] = []
            var isVia: [Bool] = []
            var viaDefs: [LayoutViaDefinition?] = []

            for shape in shapesForNet {
                geometries.append(shape.geometry)
                layers.append(shape.layer)
                isVia.append(false)
                viaDefs.append(nil)
            }

            let netVias = viasByNet[netID] ?? []
            for via in netVias {
                let rect = viaCutRect(for: via, tech: tech)
                geometries.append(.rect(rect))
                layers.append(nil)
                isVia.append(true)
                viaDefs.append(tech.viaDefinition(for: via.viaDefinitionID))
            }

            if geometries.count < 2 { continue }
            // Connectivity requires geometric intersection, so the spatial
            // index prunes candidate pairs; the union-find result is
            // independent of pair visiting order.
            let boxes = geometries.map { LayoutGeometryAnalysis.boundingBox(for: $0) }
            let grid = ShapeGridIndex(
                boundingBoxes: boxes,
                cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
            )
            var uf = LayoutUnionFind(count: geometries.count)
            for i in 0..<(geometries.count - 1) {
                for j in grid.candidateIndices(near: boxes[i]) where j > i {
                    guard uf.find(i) != uf.find(j) else { continue }
                    if shouldConnect(
                        indexA: i,
                        indexB: j,
                        geometries: geometries,
                        layers: layers,
                        isVia: isVia,
                        viaDefs: viaDefs
                    ) {
                        uf.union(i, j)
                    }
                }
            }

            let components = uf.components()
            if components.count > 1 {
                let region = overallBoundingBox(geometries: geometries) ?? .zero
                violations.append(LayoutViolation(
                    kind: .disconnectedOpen,
                    ruleID: "connectivity.open.disconnectedNet",
                    message: "Open detected in net \(netID)",
                    region: region,
                    shapeIDs: shapesForNet.map(\.id),
                    viaIDs: netVias.map(\.id),
                    netIDs: [netID],
                    suggestedFix: "Add metal or vias to connect all geometry belonging to this net."
                ))
            }
        }

        return violations
    }

    func viaCutRect(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
        if let def = tech.viaDefinition(for: via.viaDefinitionID) {
            return LayoutRect(
                origin: LayoutPoint(
                    x: via.position.x - def.cutSize.width / 2,
                    y: via.position.y - def.cutSize.height / 2
                ),
                size: def.cutSize
            )
        }
        return LayoutRect(
            origin: LayoutPoint(x: via.position.x - 0.5, y: via.position.y - 0.5),
            size: LayoutSize(width: 1, height: 1)
        )
    }

    private func shouldConnect(
        indexA: Int,
        indexB: Int,
        geometries: [LayoutGeometry],
        layers: [LayoutLayerID?],
        isVia: [Bool],
        viaDefs: [LayoutViaDefinition?]
    ) -> Bool {
        let geomA = geometries[indexA]
        let geomB = geometries[indexB]

        if !isVia[indexA] && !isVia[indexB] {
            if layers[indexA] != layers[indexB] { return false }
            return LayoutGeometryAnalysis.intersects(geomA, geomB)
        }

        if isVia[indexA] && isVia[indexB] {
            return false
        }

        let viaIndex = isVia[indexA] ? indexA : indexB
        let shapeIndex = isVia[indexA] ? indexB : indexA
        guard let def = viaDefs[viaIndex] else { return false }
        guard let shapeLayer = layers[shapeIndex] else { return false }
        if shapeLayer != def.topLayer && shapeLayer != def.bottomLayer {
            return false
        }
        return LayoutGeometryAnalysis.intersects(geomA, geomB)
    }

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
    func checkAntenna(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        pins: [LayoutPin],
        tech: LayoutTechDatabase
    ) -> [LayoutViolation] {
        guard !tech.antennaRules.isEmpty else { return [] }

        let stack: LayoutConductorStack
        do {
            stack = try LayoutConductorStack.derive(from: tech)
        } catch {
            return [LayoutViolation(
                kind: .antenna,
                ruleID: "antenna.config.conductorStack",
                message: "Antenna check could not run: \(error).",
                suggestedFix: "Fix the via/contact definitions so their bottom-to-top layer relations form a DAG."
            )]
        }

        var violations: [LayoutViolation] = []

        var stagedRules: [(rule: LayoutAntennaRule, rank: Int)] = []
        for rule in tech.antennaRules {
            guard let rank = stack.rank(of: rule.layerID) else {
                violations.append(LayoutViolation(
                    kind: .antenna,
                    ruleID: antennaRuleID(rule),
                    message: "Antenna rule on layer \(rule.layerID.name) cannot be evaluated: the layer is not part of the conductor stack.",
                    layer: rule.layerID,
                    suggestedFix: "Connect \(rule.layerID.name) into the stack with a via/contact definition or remove the rule."
                ))
                continue
            }
            stagedRules.append((rule, rank))
        }
        guard !stagedRules.isEmpty else { return violations }
        stagedRules.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return antennaRuleID($0.rule) < antennaRuleID($1.rule)
        }

        // Cut layers bridge the conductor layers of the definitions that
        // use them, becoming real once their top layer is deposited.
        struct CutBridge {
            var layers: Set<LayoutLayerID> = []
            var activationRank = Int.max
        }
        var bridgeByCutLayer: [LayoutLayerID: CutBridge] = [:]
        for def in tech.vias {
            guard let topRank = stack.rank(of: def.topLayer) else { continue }
            var bridge = bridgeByCutLayer[def.cutLayer] ?? CutBridge()
            bridge.layers.formUnion([def.bottomLayer, def.topLayer])
            bridge.activationRank = min(bridge.activationRank, topRank)
            bridgeByCutLayer[def.cutLayer] = bridge
        }
        for def in tech.contacts {
            guard let topRank = stack.rank(of: def.topLayer) else { continue }
            var bridge = bridgeByCutLayer[def.cutLayer] ?? CutBridge()
            bridge.layers.formUnion([def.bottomLayer, def.topLayer])
            bridge.activationRank = min(bridge.activationRank, topRank)
            bridgeByCutLayer[def.cutLayer] = bridge
        }

        struct Node {
            var geometry: LayoutGeometry
            var box: LayoutRect
            var layer: LayoutLayerID?
            var bridgeLayers: Set<LayoutLayerID>
            var activationRank: Int
            var shapeIndex: Int?
            var viaIndex: Int?
            var pinIndex: Int?
        }
        var nodes: [Node] = []

        for (index, shape) in shapes.enumerated() {
            let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            if let rank = stack.rank(of: shape.layer) {
                nodes.append(Node(
                    geometry: shape.geometry, box: box, layer: shape.layer,
                    bridgeLayers: [], activationRank: rank,
                    shapeIndex: index, viaIndex: nil, pinIndex: nil
                ))
            } else if let bridge = bridgeByCutLayer[shape.layer] {
                nodes.append(Node(
                    geometry: shape.geometry, box: box, layer: nil,
                    bridgeLayers: bridge.layers, activationRank: bridge.activationRank,
                    shapeIndex: index, viaIndex: nil, pinIndex: nil
                ))
            }
            // Wells, implants and markers do not conduct; they stay out.
        }

        var unknownViaDefinitionIDs: Set<String> = []
        for (index, via) in vias.enumerated() {
            let resolved: (cutSize: LayoutSize, bottom: LayoutLayerID, top: LayoutLayerID)?
            if let def = tech.viaDefinition(for: via.viaDefinitionID) {
                resolved = (def.cutSize, def.bottomLayer, def.topLayer)
            } else if let contact = tech.contactDefinition(for: via.viaDefinitionID) {
                resolved = (contact.cutSize, contact.bottomLayer, contact.topLayer)
            } else {
                resolved = nil
            }
            guard let cut = resolved, let topRank = stack.rank(of: cut.top) else {
                unknownViaDefinitionIDs.insert(via.viaDefinitionID)
                continue
            }
            let rect = LayoutRect(
                origin: LayoutPoint(
                    x: via.position.x - cut.cutSize.width / 2,
                    y: via.position.y - cut.cutSize.height / 2
                ),
                size: cut.cutSize
            )
            nodes.append(Node(
                geometry: .rect(rect), box: rect, layer: nil,
                bridgeLayers: [cut.bottom, cut.top], activationRank: topRank,
                shapeIndex: nil, viaIndex: index, pinIndex: nil
            ))
        }
        for definitionID in unknownViaDefinitionIDs.sorted() {
            violations.append(LayoutViolation(
                kind: .antenna,
                ruleID: "antenna.config.viaDefinition",
                message: "Antenna connectivity cannot include vias with unknown definition '\(definitionID)'.",
                suggestedFix: "Add the via/contact definition to the technology database."
            ))
        }

        for (index, pin) in pins.enumerated() {
            guard let rank = stack.rank(of: pin.layer) else {
                if pin.role == .gate {
                    violations.append(LayoutViolation(
                        kind: .antenna,
                        ruleID: "antenna.config.gatePinLayer",
                        message: "Gate pin '\(pin.name)' sits on layer \(pin.layer.name) outside the conductor stack; its antenna exposure cannot be evaluated.",
                        layer: pin.layer,
                        pinIDs: [pin.id],
                        suggestedFix: "Place the gate pin on a conductor-stack layer or connect its layer with a via/contact definition."
                    ))
                }
                continue
            }
            let rect = LayoutRect(
                origin: LayoutPoint(
                    x: pin.position.x - pin.size.width / 2,
                    y: pin.position.y - pin.size.height / 2
                ),
                size: pin.size
            )
            nodes.append(Node(
                geometry: .rect(rect), box: rect, layer: pin.layer,
                bridgeLayers: [], activationRank: rank,
                shapeIndex: nil, viaIndex: nil, pinIndex: index
            ))
        }

        guard !nodes.isEmpty else { return violations }

        let boxes = nodes.map(\.box)
        let grid = ShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
        )
        var unionFind = LayoutUnionFind(count: nodes.count)
        var active = [Bool](repeating: false, count: nodes.count)
        let activationOrder = nodes.indices.sorted {
            if nodes[$0].activationRank != nodes[$1].activationRank {
                return nodes[$0].activationRank < nodes[$1].activationRank
            }
            return $0 < $1
        }
        var activationCursor = 0

        func connects(_ a: Int, _ b: Int) -> Bool {
            let nodeA = nodes[a]
            let nodeB = nodes[b]
            let aIsBridge = !nodeA.bridgeLayers.isEmpty
            let bIsBridge = !nodeB.bridgeLayers.isEmpty
            if aIsBridge && bIsBridge { return false }
            // Pins are abstract terminals; they attach through geometry but
            // never join each other directly.
            if nodeA.pinIndex != nil && nodeB.pinIndex != nil { return false }
            if aIsBridge || bIsBridge {
                let bridge = aIsBridge ? nodeA : nodeB
                let conductor = aIsBridge ? nodeB : nodeA
                guard let layer = conductor.layer, bridge.bridgeLayers.contains(layer) else {
                    return false
                }
            } else {
                guard nodeA.layer == nodeB.layer else { return false }
            }
            return LayoutGeometryAnalysis.intersects(nodeA.geometry, nodeB.geometry)
        }

        func activate(upTo rank: Int) {
            while activationCursor < activationOrder.count,
                  nodes[activationOrder[activationCursor]].activationRank <= rank {
                let index = activationOrder[activationCursor]
                activationCursor += 1
                active[index] = true
                for candidate in grid.candidateIndices(near: nodes[index].box)
                where candidate != index && active[candidate] {
                    guard unionFind.find(index) != unionFind.find(candidate) else { continue }
                    if connects(index, candidate) {
                        unionFind.union(index, candidate)
                    }
                }
            }
        }

        let dbu = tech.units.dbuPerMicron
        let rulesByRank = Dictionary(grouping: stagedRules, by: { $0.rank })

        for rank in rulesByRank.keys.sorted() {
            activate(upTo: rank)

            var componentMembers: [Int: [Int]] = [:]
            for index in nodes.indices where active[index] {
                componentMembers[unionFind.find(index), default: []].append(index)
            }
            // Members were appended in ascending node order, so the first
            // member orders components deterministically.
            let components = componentMembers.values.sorted { $0[0] < $1[0] }

            for component in components {
                var gatePins: [LayoutPin] = []
                var hasDischarge = false
                var componentShapes: [LayoutShape] = []
                var componentViaIDs: [UUID] = []
                for index in component {
                    let node = nodes[index]
                    if let pinIndex = node.pinIndex {
                        switch pins[pinIndex].role {
                        case .gate:
                            gatePins.append(pins[pinIndex])
                        case .source, .drain, .bulk:
                            hasDischarge = true
                        case .signal, .power, .ground:
                            break
                        }
                    }
                    if let shapeIndex = node.shapeIndex, node.layer != nil {
                        componentShapes.append(shapes[shapeIndex])
                    }
                    if let viaIndex = node.viaIndex {
                        componentViaIDs.append(vias[viaIndex].id)
                    }
                }
                if hasDischarge { continue }
                let gateArea = gatePins.reduce(0.0) { $0 + ($1.size.width * $1.size.height) }
                if gateArea <= 0 { continue }

                let componentNetIDs = antennaComponentNetIDs(shapes: componentShapes, pins: gatePins)

                for staged in rulesByRank[rank] ?? [] {
                    let rule = staged.rule
                    let layerShapes = componentShapes.filter { $0.layer == rule.layerID }
                    let layerArea = mergedArea(of: layerShapes, dbu: dbu)
                    if layerArea > 0 {
                        let ratio = layerArea / gateArea
                        if ratio > rule.maxRatio {
                            violations.append(LayoutViolation(
                                kind: .antenna,
                                ruleID: antennaRuleID(rule),
                                message: "Antenna violation at the \(rule.layerID.name) etch stage: ratio \(ratio) exceeds \(rule.maxRatio).",
                                layer: rule.layerID,
                                region: overallBoundingBox(shapes: layerShapes) ?? .zero,
                                measured: ratio,
                                required: rule.maxRatio,
                                unit: "ratio",
                                shapeIDs: layerShapes.map(\.id),
                                viaIDs: componentViaIDs,
                                pinIDs: gatePins.map(\.id),
                                netIDs: componentNetIDs,
                                suggestedFix: "Insert an upper-layer jumper near the gate, add an antenna diode or diffusion tie, or reduce the metal area collected before the gate."
                            ))
                        }
                    }

                    if let maxCumulative = rule.maxCumulativeRatio {
                        var seenLayers: Set<LayoutLayerID> = []
                        var cumulativeArea = 0.0
                        var cumulativeShapes: [LayoutShape] = []
                        for contributing in stagedRules where contributing.rank <= rank {
                            guard seenLayers.insert(contributing.rule.layerID).inserted else { continue }
                            let shapesOnLayer = componentShapes.filter { $0.layer == contributing.rule.layerID }
                            cumulativeArea += mergedArea(of: shapesOnLayer, dbu: dbu)
                            cumulativeShapes.append(contentsOf: shapesOnLayer)
                        }
                        guard cumulativeArea > 0 else { continue }
                        let ratio = cumulativeArea / gateArea
                        if ratio > maxCumulative {
                            violations.append(LayoutViolation(
                                kind: .antenna,
                                ruleID: cumulativeAntennaRuleID(rule),
                                message: "Cumulative antenna violation at the \(rule.layerID.name) etch stage: ratio \(ratio) exceeds \(maxCumulative).",
                                layer: rule.layerID,
                                region: overallBoundingBox(shapes: cumulativeShapes) ?? .zero,
                                measured: ratio,
                                required: maxCumulative,
                                unit: "ratio",
                                shapeIDs: cumulativeShapes.map(\.id),
                                viaIDs: componentViaIDs,
                                pinIDs: gatePins.map(\.id),
                                netIDs: componentNetIDs,
                                suggestedFix: "Insert an upper-layer jumper near the gate, add an antenna diode or diffusion tie, or reduce the total metal area collected before the gate."
                            ))
                        }
                    }
                }
            }
        }

        return violations
    }

    private func antennaComponentNetIDs(shapes: [LayoutShape], pins: [LayoutPin]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for shape in shapes {
            guard let netID = shape.netID, seen.insert(netID).inserted else { continue }
            result.append(netID)
        }
        for pin in pins {
            guard let netID = pin.netID, seen.insert(netID).inserted else { continue }
            result.append(netID)
        }
        return result
    }

    /// Boolean-merged area in square microns; overlapping shapes count once.
    private func mergedArea(of shapes: [LayoutShape], dbu: Double) -> Double {
        guard !shapes.isEmpty else { return 0 }
        let region = mergedRegion(of: shapes, dbu: dbu)
        return abs(Double(region.area)) / (dbu * dbu)
    }

    /// Layer-pair enclosure is checked per connected inner component, and only
    /// where the inner component interacts with the outer layer: features that
    /// never touch the outer layer are outside the rule's scope (e.g. NMOS
    /// active against NWELL). Interacting components must be fully covered with
    /// the required margin unless the rule allows pass-through, in which case
    /// only the covered portion is constrained and the crossing is masked.
    /// `rules` restricts which enclosure rules are evaluated (nil checks
    /// every rule in the technology database); each rule's verdict depends
    /// only on the geometry of its own outer and inner layers.
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

    /// Thickness of a margin-deficit region: the deficit hugs the outer
    /// boundary as bands, so the smallest bounding-box dimension over its
    /// polygons is the missing margin. The component bounding box would
    /// overestimate ring-shaped deficits.
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

    private struct ViaEnclosureCheck: Sendable {
        let passed: Bool
        let measured: Double
    }

    /// `candidates` must contain every same-layer shape whose bounding box
    /// intersects the cut rect expanded by `enclosure` (callers pass spatial
    /// index results); shapes farther away cannot affect the verdict.
    private func viaEnclosureCheck(
        cutRect: LayoutRect,
        enclosure: Double,
        candidates: [LayoutShape],
        dbu: Double
    ) -> ViaEnclosureCheck {
        guard !candidates.isEmpty else {
            return ViaEnclosureCheck(passed: false, measured: 0)
        }

        // Coverage of the required halo by the merged candidate region is the
        // authoritative test: several abutting shapes may jointly enclose the
        // cut even when no single shape does. The single-shape `measured`
        // value is kept for reporting only.
        let outerRegion = shapesToRegion(candidates, dbu: dbu)
        let requiredRegion = rectToRegion(cutRect.expanded(by: enclosure, enclosure), dbu: dbu)
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

    private func antennaRuleID(_ rule: LayoutAntennaRule) -> String {
        "antenna.\(rule.layerID.name).\(rule.layerID.purpose).maxRatio"
    }

    private func cumulativeAntennaRuleID(_ rule: LayoutAntennaRule) -> String {
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
    private func contributingShapes(_ shapes: [LayoutShape], around rect: LayoutRect) -> [LayoutShape] {
        shapes.filter { LayoutGeometryAnalysis.boundingBox(for: $0.geometry).intersects(rect) }
    }

    private func uniqueNetIDs(of shapes: [LayoutShape]) -> [UUID] {
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

    private func shapesToRegion(_ shapes: [LayoutShape], dbu: Double) -> Region {
        var boundaries: [IRBoundary] = []
        for shape in shapes {
            if let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu) {
                boundaries.append(boundary)
            }
        }
        return Region(polygons: boundaries)
    }

    private func rectToRegion(_ rect: LayoutRect, dbu: Double) -> Region {
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
        let allX = [pair.edge1.p1.x, pair.edge1.p2.x, pair.edge2.p1.x, pair.edge2.p2.x]
        let allY = [pair.edge1.p1.y, pair.edge1.p2.y, pair.edge2.p1.y, pair.edge2.p2.y]
        let minX = Double(allX.min()!) / dbu
        let minY = Double(allY.min()!) / dbu
        let maxX = Double(allX.max()!) / dbu
        let maxY = Double(allY.max()!) / dbu
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
        )
    }

    func overallBoundingBox(shapes: [LayoutShape]) -> LayoutRect? {
        let boxes = shapes.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        return overallBoundingBox(rects: boxes)
    }

    private func overallBoundingBox(geometries: [LayoutGeometry]) -> LayoutRect? {
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
