import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
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

        let nets = Dictionary(grouping: netShapes.compactMap { shape -> (UUID, LayoutShape)? in
            guard let netID = shape.netID else { return nil }
            return (netID, shape)
        }, by: { $0.0 }).mapValues { entries in entries.map(\.1) }
        let viasByNet = Dictionary(grouping: vias.compactMap { via -> (UUID, LayoutVia)? in
            guard let netID = via.netID else { return nil }
            return (netID, via)
        }, by: { $0.0 }).mapValues { entries in entries.map(\.1) }
        for (netID, shapesForNet) in nets {
            var geometries: [LayoutGeometry] = []
            var layers: [LayoutLayerID?] = []
            var isVia: [Bool] = []
            var viaDefs: [LayoutViaDefinition?] = []
            var viaCutRects: [[LayoutRect]] = []
            var viaContactRectsByLayer: [[LayoutLayerID: [LayoutRect]]] = []

            for shape in shapesForNet {
                geometries.append(shape.geometry)
                layers.append(shape.layer)
                isVia.append(false)
                viaDefs.append(nil)
                viaCutRects.append([])
                viaContactRectsByLayer.append([:])
            }

            let netVias = viasByNet[netID] ?? []
            for via in netVias {
                let cutRects = self.viaCutRects(for: via, tech: tech)
                let conductorRects = viaConductorRects(for: via, tech: tech)
                let bounds = union(rects: conductorRects) ?? viaCutBoundingBox(for: via, tech: tech)
                let definition = tech.viaDefinition(for: via.viaDefinitionID)
                geometries.append(.rect(bounds))
                layers.append(nil)
                isVia.append(true)
                viaDefs.append(definition)
                viaCutRects.append(cutRects)
                viaContactRectsByLayer.append(self.viaContactRectsByLayer(for: via, tech: tech))
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
                        viaDefs: viaDefs,
                        viaCutRects: viaCutRects,
                        viaContactRectsByLayer: viaContactRectsByLayer
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

    func viaCutRects(for via: LayoutVia, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [fallbackViaCutRect(for: via)]
        }

        let explicitRects = def.layerGeometries
            .filter { $0.layer == def.cutLayer }
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
        guard !explicitRects.isEmpty else {
            return [defaultViaCutRect(for: via, definition: def)]
        }
        return explicitRects.map { translated($0, by: via.position) }
    }

    func viaLayerRects(for via: LayoutVia, layer: LayoutLayerID, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return []
        }
        let explicitRects = explicitViaLayerRects(for: via, layer: layer, tech: tech)
        if !explicitRects.isEmpty {
            return explicitRects
        }
        if layer == def.cutLayer || layer == def.topLayer || layer == def.bottomLayer {
            return viaCutRects(for: via, tech: tech)
        }
        return []
    }

    func explicitViaLayerRects(
        for via: LayoutVia,
        layer: LayoutLayerID,
        tech: LayoutTechDatabase
    ) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return []
        }
        return def.layerGeometries
            .filter { $0.layer == layer }
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
            .map { translated($0, by: via.position) }
    }

    func viaConductorRects(for via: LayoutVia, tech: LayoutTechDatabase) -> [LayoutRect] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [fallbackViaCutRect(for: via)]
        }
        let explicitRects = def.layerGeometries
            .flatMap(\.rects)
            .filter { $0.size.width > 0 && $0.size.height > 0 }
        if !explicitRects.isEmpty {
            return explicitRects.map { translated($0, by: via.position) }
        }
        return viaCutRects(for: via, tech: tech)
    }

    func viaContactRectsByLayer(
        for via: LayoutVia,
        tech: LayoutTechDatabase
    ) -> [LayoutLayerID: [LayoutRect]] {
        guard let def = tech.viaDefinition(for: via.viaDefinitionID) else {
            return [:]
        }
        var result: [LayoutLayerID: [LayoutRect]] = [:]
        for layer in Set([def.topLayer, def.bottomLayer]) {
            result[layer] = viaLayerRects(for: via, layer: layer, tech: tech)
        }
        return result
    }

    func viaCutBoundingBox(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
        union(rects: viaCutRects(for: via, tech: tech)) ?? fallbackViaCutRect(for: via)
    }

    func viaCutRect(for via: LayoutVia, tech: LayoutTechDatabase) -> LayoutRect {
        viaCutBoundingBox(for: via, tech: tech)
    }

    func unknownViaDefinitionViolation(for via: LayoutVia) -> LayoutViolation {
        LayoutViolation(
            kind: .ruleCoverage,
            ruleID: "via.\(via.viaDefinitionID).definition",
            message: "Via \(via.viaDefinitionID) is used but has no technology definition.",
            region: fallbackViaCutRect(for: via),
            measured: 1,
            required: 0,
            unit: "missing-definition",
            viaIDs: [via.id],
            netIDs: via.netID.map { [$0] } ?? [],
            suggestedFix: "Add the via/contact definition to the technology database or replace the via with a defined stack element."
        )
    }

    func union(rects: [LayoutRect]) -> LayoutRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private func defaultViaCutRect(for via: LayoutVia, definition: LayoutViaDefinition) -> LayoutRect {
        return LayoutRect(
            origin: LayoutPoint(
                x: via.position.x - definition.cutSize.width / 2,
                y: via.position.y - definition.cutSize.height / 2
            ),
            size: definition.cutSize
        )
    }

    private func fallbackViaCutRect(for via: LayoutVia) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: via.position.x - 0.5, y: via.position.y - 0.5),
            size: LayoutSize(width: 1, height: 1)
        )
    }

    private func translated(_ rect: LayoutRect, by point: LayoutPoint) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: rect.origin.x + point.x, y: rect.origin.y + point.y),
            size: rect.size
        )
    }

    func shouldConnect(
        indexA: Int,
        indexB: Int,
        geometries: [LayoutGeometry],
        layers: [LayoutLayerID?],
        isVia: [Bool],
        viaDefs: [LayoutViaDefinition?],
        viaCutRects: [[LayoutRect]]? = nil,
        viaContactRectsByLayer: [[LayoutLayerID: [LayoutRect]]]? = nil
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
        let shapeGeometry = geometries[shapeIndex]
        if let contactRects = viaContactRectsByLayer?[safe: viaIndex]?[shapeLayer],
           !contactRects.isEmpty {
            return contactRects.contains {
                LayoutGeometryAnalysis.boundingBox(for: shapeGeometry).intersects($0)
                    && LayoutGeometryAnalysis.intersects(shapeGeometry, .rect($0))
            }
        }
        if let cutRects = viaCutRects?[safe: viaIndex], !cutRects.isEmpty {
            return cutRects.contains {
                LayoutGeometryAnalysis.boundingBox(for: shapeGeometry).intersects($0)
                    && LayoutGeometryAnalysis.intersects(shapeGeometry, .rect($0))
            }
        }
        let viaGeometry = geometries[viaIndex]
        return LayoutGeometryAnalysis.intersects(viaGeometry, shapeGeometry)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
