import Foundation
import LayoutCore
import LayoutTech

public struct LayoutDRCService {
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
        flatten(
            cell: targetCell,
            document: document,
            transforms: [],
            shapes: &flattenedShapes,
            vias: &flattenedVias,
            pins: &flattenedPins
        )

        var violations: [LayoutViolation] = []

        violations.append(contentsOf: checkWidthAndArea(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkSpacing(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkViaEnclosure(shapes: flattenedShapes, vias: flattenedVias, tech: tech))
        violations.append(contentsOf: checkDensity(shapes: flattenedShapes, tech: tech))
        violations.append(contentsOf: checkShorts(shapes: flattenedShapes))
        violations.append(contentsOf: checkOpens(shapes: flattenedShapes, vias: flattenedVias, tech: tech))
        violations.append(contentsOf: checkAntenna(shapes: flattenedShapes, pins: flattenedPins, tech: tech))

        return LayoutDRCResult(violations: violations)
    }

    private func resolveCell(document: LayoutDocument, cellID: UUID?) -> LayoutCell? {
        if let id = cellID {
            return document.cell(withID: id)
        }
        if let topID = document.topCellID {
            return document.cell(withID: topID)
        }
        return document.cells.first
    }

    private func flatten(
        cell: LayoutCell,
        document: LayoutDocument,
        transforms: [LayoutTransform],
        shapes: inout [LayoutShape],
        vias: inout [LayoutVia],
        pins: inout [LayoutPin]
    ) {
        for shape in cell.shapes {
            var transformed = shape
            transformed.geometry = applyTransforms(to: shape.geometry, transforms: transforms)
            shapes.append(transformed)
        }

        for via in cell.vias {
            var transformed = via
            transformed.position = applyTransforms(to: via.position, transforms: transforms)
            vias.append(transformed)
        }

        for pin in cell.pins {
            var transformed = pin
            transformed.position = applyTransforms(to: pin.position, transforms: transforms)
            pins.append(transformed)
        }

        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            flatten(
                cell: child,
                document: document,
                transforms: transforms + [instance.transform],
                shapes: &shapes,
                vias: &vias,
                pins: &pins
            )
        }
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

    private func checkWidthAndArea(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        for shape in shapes {
            guard let rules = tech.ruleSet(for: shape.layer) else { continue }
            let minWidth = LayoutGeometryUtils.minimumWidth(of: shape.geometry)
            if minWidth > 0 && minWidth < rules.minWidth {
                let region = LayoutGeometryUtils.boundingBox(for: shape.geometry)
                violations.append(LayoutViolation(
                    kind: .minWidth,
                    message: "Min width violation on \(shape.layer.name). Required \(rules.minWidth), got \(minWidth)",
                    layer: shape.layer,
                    region: region
                ))
            }
            let area = LayoutGeometryUtils.area(of: shape.geometry)
            if area > 0 && area < rules.minArea {
                let region = LayoutGeometryUtils.boundingBox(for: shape.geometry)
                violations.append(LayoutViolation(
                    kind: .minArea,
                    message: "Min area violation on \(shape.layer.name). Required \(rules.minArea), got \(area)",
                    layer: shape.layer,
                    region: region
                ))
            }
        }
        return violations
    }

    private func checkSpacing(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            if layerShapes.count < 2 { continue }
            for i in 0..<(layerShapes.count - 1) {
                let a = layerShapes[i]
                for j in (i + 1)..<layerShapes.count {
                    let b = layerShapes[j]
                    if let na = a.netID, let nb = b.netID, na == nb { continue }
                    let dist = LayoutGeometryUtils.minimumDistance(between: a.geometry, and: b.geometry)
                    if dist < rules.minSpacing {
                        let region = LayoutGeometryUtils.boundingBox(for: a.geometry).union(
                            LayoutGeometryUtils.boundingBox(for: b.geometry)
                        )
                        violations.append(LayoutViolation(
                            kind: .minSpacing,
                            message: "Min spacing violation on \(layer.name). Required \(rules.minSpacing), got \(dist)",
                            layer: layer,
                            region: region
                        ))
                    }
                }
            }
        }
        return violations
    }

    private func checkViaEnclosure(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        tech: LayoutTechDatabase
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        for via in vias {
            guard let def = tech.viaDefinition(for: via.viaDefinitionID) else { continue }
            let cutRect = LayoutRect(
                origin: LayoutPoint(
                    x: via.position.x - def.cutSize.width / 2,
                    y: via.position.y - def.cutSize.height / 2
                ),
                size: def.cutSize
            )
            let topEnclosure = cutRect.expanded(by: def.enclosure.top, def.enclosure.top)
            let bottomEnclosure = cutRect.expanded(by: def.enclosure.bottom, def.enclosure.bottom)

            let topMatch = shapes.contains { shape in
                shape.layer == def.topLayer && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(topEnclosure.center)
                    && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(LayoutPoint(x: topEnclosure.minX, y: topEnclosure.minY))
                    && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(LayoutPoint(x: topEnclosure.maxX, y: topEnclosure.maxY))
            }
            let bottomMatch = shapes.contains { shape in
                shape.layer == def.bottomLayer && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(bottomEnclosure.center)
                    && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(LayoutPoint(x: bottomEnclosure.minX, y: bottomEnclosure.minY))
                    && LayoutGeometryUtils.boundingBox(for: shape.geometry).contains(LayoutPoint(x: bottomEnclosure.maxX, y: bottomEnclosure.maxY))
            }

            if !topMatch || !bottomMatch {
                violations.append(LayoutViolation(
                    kind: .enclosure,
                    message: "Via enclosure violation for \(via.viaDefinitionID)",
                    layer: def.cutLayer,
                    region: cutRect
                ))
            }
        }
        return violations
    }

    private func checkDensity(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        guard let overall = overallBoundingBox(shapes: shapes) else { return violations }
        let overallArea = overall.size.width * overall.size.height
        if overallArea == 0 { return violations }

        let grouped = Dictionary(grouping: shapes, by: { $0.layer })
        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            let area = layerShapes.reduce(0.0) { $0 + LayoutGeometryUtils.area(of: $1.geometry) }
            let density = area / overallArea
            if density < rules.minDensity || density > rules.maxDensity {
                violations.append(LayoutViolation(
                    kind: .density,
                    message: "Density violation on \(layer.name). Range \(rules.minDensity)-\(rules.maxDensity), got \(density)",
                    layer: layer,
                    region: overall
                ))
            }
        }
        return violations
    }

    private func checkShorts(shapes: [LayoutShape]) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        if shapes.count < 2 { return violations }
        for i in 0..<(shapes.count - 1) {
            let a = shapes[i]
            for j in (i + 1)..<shapes.count {
                let b = shapes[j]
                if let na = a.netID, let nb = b.netID, na == nb { continue }
                if LayoutGeometryUtils.intersects(a.geometry, b.geometry) {
                    let region = LayoutGeometryUtils.boundingBox(for: a.geometry).union(
                        LayoutGeometryUtils.boundingBox(for: b.geometry)
                    )
                    violations.append(LayoutViolation(
                        kind: .overlapShort,
                        message: "Short between shapes on different nets",
                        layer: a.layer,
                        region: region
                    ))
                }
            }
        }
        return violations
    }

    private func checkOpens(shapes: [LayoutShape], vias: [LayoutVia], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let netShapes = shapes.filter { $0.netID != nil }
        if netShapes.isEmpty { return violations }

        let nets = Dictionary(grouping: netShapes, by: { $0.netID! })
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

            let netVias = vias.filter { $0.netID == netID }
            for via in netVias {
                let rect = viaCutRect(for: via, tech: tech)
                geometries.append(.rect(rect))
                layers.append(nil)
                isVia.append(true)
                viaDefs.append(tech.viaDefinition(for: via.viaDefinitionID))
            }

            if geometries.count < 2 { continue }
            var uf = LayoutUnionFind(count: geometries.count)
            for i in 0..<(geometries.count - 1) {
                for j in (i + 1)..<geometries.count {
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
                    message: "Open detected in net \(netID)",
                    region: region
                ))
            }
        }

        return violations
    }

    private func viaCutRect(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
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
            return LayoutGeometryUtils.intersects(geomA, geomB)
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
        return LayoutGeometryUtils.intersects(geomA, geomB)
    }

    private func checkAntenna(
        shapes: [LayoutShape],
        pins: [LayoutPin],
        tech: LayoutTechDatabase
    ) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let shapesByNet = Dictionary(grouping: shapes.filter { $0.netID != nil }, by: { $0.netID! })
        let pinsByNet = Dictionary(grouping: pins.filter { $0.netID != nil }, by: { $0.netID! })

        for (netID, netShapes) in shapesByNet {
            let netPins = pinsByNet[netID] ?? []
            let gateArea = netPins.filter { $0.role == .gate }
                .reduce(0.0) { $0 + ($1.size.width * $1.size.height) }
            if gateArea <= 0 { continue }

            for rule in tech.antennaRules {
                let metalArea = netShapes
                    .filter { $0.layer == rule.layerID }
                    .reduce(0.0) { $0 + LayoutGeometryUtils.area(of: $1.geometry) }
                if metalArea <= 0 { continue }
                let ratio = metalArea / gateArea
                if ratio > rule.maxRatio {
                    let region = overallBoundingBox(shapes: netShapes) ?? .zero
                    violations.append(LayoutViolation(
                        kind: .antenna,
                        message: "Antenna violation on net \(netID). Ratio \(ratio) exceeds \(rule.maxRatio)",
                        layer: rule.layerID,
                        region: region
                    ))
                }
            }
        }

        return violations
    }

    private func overallBoundingBox(shapes: [LayoutShape]) -> LayoutRect? {
        let boxes = shapes.map { LayoutGeometryUtils.boundingBox(for: $0.geometry) }
        return overallBoundingBox(rects: boxes)
    }

    private func overallBoundingBox(geometries: [LayoutGeometry]) -> LayoutRect? {
        let boxes = geometries.map { LayoutGeometryUtils.boundingBox(for: $0) }
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
