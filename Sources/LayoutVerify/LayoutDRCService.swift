import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import GeometryOps

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
        violations.append(contentsOf: checkEnclosureRules(shapes: flattenedShapes, tech: tech))
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
        let dbu = tech.units.dbuPerMicron
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })

        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }

            // Edge-based width check via GeometryOps Region
            let minWidthDBU = Int32((rules.minWidth * dbu).rounded())
            if minWidthDBU > 0 {
                let region = shapesToRegion(layerShapes, dbu: dbu)
                let widthPairs = region.widthViolations(minWidth: minWidthDBU, metric: .euclidean)
                for pair in widthPairs {
                    let rect = edgePairToRect(pair, dbu: dbu)
                    let measured = pair.distance / dbu
                    violations.append(LayoutViolation(
                        kind: .minWidth,
                        message: "Min width violation on \(layer.name). Required \(rules.minWidth)µm, measured \(String(format: "%.3f", measured))µm",
                        layer: layer,
                        region: rect
                    ))
                }
            }

            // Area check (simple calculation, no Region needed)
            for shape in layerShapes {
                let area = LayoutGeometryUtils.area(of: shape.geometry)
                if area > 0 && area < rules.minArea {
                    let rect = LayoutGeometryUtils.boundingBox(for: shape.geometry)
                    violations.append(LayoutViolation(
                        kind: .minArea,
                        message: "Min area violation on \(layer.name). Required \(rules.minArea), got \(area)",
                        layer: layer,
                        region: rect
                    ))
                }
            }
        }
        return violations
    }

    private func checkSpacing(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let dbu = tech.units.dbuPerMicron
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })

        for (layer, layerShapes) in grouped {
            guard let rules = tech.ruleSet(for: layer) else { continue }
            if layerShapes.count < 2 { continue }
            let minSpaceDBU = Int32((rules.minSpacing * dbu).rounded())
            if minSpaceDBU <= 0 { continue }

            // Edge-based spacing check via GeometryOps Region
            for i in 0..<(layerShapes.count - 1) {
                let a = layerShapes[i]
                for j in (i + 1)..<layerShapes.count {
                    let b = layerShapes[j]
                    if let na = a.netID, let nb = b.netID, na == nb { continue }

                    let regionA = shapesToRegion([a], dbu: dbu)
                    let regionB = shapesToRegion([b], dbu: dbu)
                    let spacePairs = regionA.spaceViolations(to: regionB, minSpace: minSpaceDBU)

                    for pair in spacePairs {
                        let rect = edgePairToRect(pair, dbu: dbu)
                        let measured = pair.distance / dbu
                        violations.append(LayoutViolation(
                            kind: .minSpacing,
                            message: "Min spacing violation on \(layer.name). Required \(rules.minSpacing)µm, measured \(String(format: "%.3f", measured))µm",
                            layer: layer,
                            region: rect
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

    private func checkEnclosureRules(shapes: [LayoutShape], tech: LayoutTechDatabase) -> [LayoutViolation] {
        var violations: [LayoutViolation] = []
        let dbu = tech.units.dbuPerMicron
        let grouped = Dictionary(grouping: shapes, by: { $0.layer })

        for rule in tech.enclosureRules {
            guard let outerShapes = grouped[rule.outerLayer], !outerShapes.isEmpty else { continue }
            guard let innerShapes = grouped[rule.innerLayer], !innerShapes.isEmpty else { continue }

            let minEncDBU = Int32((rule.minEnclosure * dbu).rounded())
            if minEncDBU <= 0 { continue }

            let outerRegion = shapesToRegion(outerShapes, dbu: dbu)
            let innerRegion = shapesToRegion(innerShapes, dbu: dbu)
            let encPairs = outerRegion.enclosureViolations(inner: innerRegion, minEnclosure: minEncDBU)

            for pair in encPairs {
                let rect = edgePairToRect(pair, dbu: dbu)
                let measured = pair.distance / dbu
                violations.append(LayoutViolation(
                    kind: .enclosure,
                    message: "Enclosure violation: \(rule.innerLayer.name) must be enclosed by \(rule.outerLayer.name) by at least \(rule.minEnclosure)µm, measured \(String(format: "%.3f", measured))µm",
                    layer: rule.innerLayer,
                    region: rect
                ))
            }
        }
        return violations
    }

    // MARK: - GeometryOps Bridge

    private func shapesToRegion(_ shapes: [LayoutShape], dbu: Double) -> Region {
        var boundaries: [IRBoundary] = []
        for shape in shapes {
            if let boundary = geometryToIRBoundary(shape.geometry, dbu: dbu) {
                boundaries.append(boundary)
            }
        }
        return Region(polygons: boundaries)
    }

    private func geometryToIRBoundary(_ geometry: LayoutGeometry, dbu: Double) -> IRBoundary? {
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
