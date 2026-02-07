import Foundation
import LayoutCore
import LayoutTech
import LayoutIR

/// Converts between IRLibrary (GDSII/OASIS intermediate representation)
/// and LayoutDocument (editor-native model).
public struct IRLayoutBridge: Sendable {

    public init() {}

    // MARK: - Import: IRLibrary → LayoutDocument

    public func importLibrary(_ library: IRLibrary, tech: LayoutTechDatabase) -> LayoutDocument {
        let dbu = library.units.dbuPerMicron
        let layerMap = buildLayerMap(tech: tech)

        // Build cell name → UUID mapping first (for instance references)
        var cellNameToID: [String: UUID] = [:]
        for irCell in library.cells {
            cellNameToID[irCell.name] = UUID()
        }

        var cells: [LayoutCell] = []
        for irCell in library.cells {
            let cellID = cellNameToID[irCell.name]!
            let cell = convertCell(irCell, cellID: cellID, dbu: dbu, layerMap: layerMap, cellNameToID: cellNameToID)
            cells.append(cell)
        }

        let topCellID = cells.last?.id
        return LayoutDocument(
            name: library.name,
            units: LayoutUnits(dbuPerMicron: dbu),
            cells: cells,
            topCellID: topCellID
        )
    }

    // MARK: - Export: LayoutDocument → IRLibrary

    public func exportLibrary(_ document: LayoutDocument, tech: LayoutTechDatabase) -> IRLibrary {
        let dbu = document.units.dbuPerMicron
        let reverseLayerMap = buildReverseLayerMap(tech: tech)

        // Build cell UUID → name mapping
        var cellIDToName: [UUID: String] = [:]
        for cell in document.cells {
            cellIDToName[cell.id] = cell.name
        }

        var irCells: [IRCell] = []
        for cell in document.cells {
            let irCell = convertToIRCell(cell, dbu: dbu, reverseLayerMap: reverseLayerMap, cellIDToName: cellIDToName)
            irCells.append(irCell)
        }

        return IRLibrary(
            name: document.name,
            units: IRUnits(dbuPerMicron: dbu),
            cells: irCells
        )
    }

    // MARK: - Private: Import helpers

    private func convertCell(
        _ irCell: IRCell,
        cellID: UUID,
        dbu: Double,
        layerMap: [LayerKey: LayoutLayerID],
        cellNameToID: [String: UUID]
    ) -> LayoutCell {
        var shapes: [LayoutShape] = []
        var labels: [LayoutLabel] = []
        var instances: [LayoutInstance] = []

        for element in irCell.elements {
            switch element {
            case .boundary(let b):
                if let shape = convertBoundary(b, dbu: dbu, layerMap: layerMap) {
                    shapes.append(shape)
                }
            case .path(let p):
                if let shape = convertPath(p, dbu: dbu, layerMap: layerMap) {
                    shapes.append(shape)
                }
            case .text(let t):
                if let label = convertText(t, dbu: dbu, layerMap: layerMap) {
                    labels.append(label)
                }
            case .cellRef(let r):
                if let inst = convertCellRef(r, dbu: dbu, cellNameToID: cellNameToID) {
                    instances.append(inst)
                }
            case .arrayRef(let a):
                instances.append(contentsOf: convertArrayRef(a, dbu: dbu, cellNameToID: cellNameToID))
            }
        }

        return LayoutCell(
            id: cellID,
            name: irCell.name,
            shapes: shapes,
            labels: labels,
            instances: instances
        )
    }

    private func convertBoundary(_ b: IRBoundary, dbu: Double, layerMap: [LayerKey: LayoutLayerID]) -> LayoutShape? {
        let layerID = resolveLayer(gdsLayer: Int(b.layer), gdsDatatype: Int(b.datatype), layerMap: layerMap)
        // Remove closing point (GDSII requires first == last, LayoutPolygon does not)
        var pts = b.points.map { dbuToMicron($0, dbu: dbu) }
        if pts.count > 1 && pts.first == pts.last {
            pts.removeLast()
        }
        guard pts.count >= 3 else { return nil }
        return LayoutShape(
            layer: layerID,
            geometry: .polygon(LayoutPolygon(points: pts))
        )
    }

    private func convertPath(_ p: IRPath, dbu: Double, layerMap: [LayerKey: LayoutLayerID]) -> LayoutShape? {
        let layerID = resolveLayer(gdsLayer: Int(p.layer), gdsDatatype: Int(p.datatype), layerMap: layerMap)
        let pts = p.points.map { dbuToMicron($0, dbu: dbu) }
        let width = Double(p.width) / dbu
        guard pts.count >= 2 && width > 0 else { return nil }
        let endCap: LayoutPathEndCap
        switch p.pathType {
        case .flush: endCap = .truncate
        case .round: endCap = .round
        case .halfWidthExtend, .customExtension: endCap = .extend
        }
        return LayoutShape(
            layer: layerID,
            geometry: .path(LayoutPath(points: pts, width: width, endCap: endCap))
        )
    }

    private func convertText(_ t: IRText, dbu: Double, layerMap: [LayerKey: LayoutLayerID]) -> LayoutLabel? {
        let layerID = resolveLayer(gdsLayer: Int(t.layer), gdsDatatype: Int(t.texttype), layerMap: layerMap)
        let pos = dbuToMicron(t.position, dbu: dbu)
        return LayoutLabel(text: t.string, position: pos, layer: layerID)
    }

    private func convertCellRef(_ r: IRCellRef, dbu: Double, cellNameToID: [String: UUID]) -> LayoutInstance? {
        guard let cellID = cellNameToID[r.cellName] else { return nil }
        let origin = dbuToMicron(r.origin, dbu: dbu)
        let rotation = angleToRotation(r.transform.angle)
        let transform = LayoutTransform(
            translation: origin,
            rotation: rotation,
            mirrorX: r.transform.mirrorX
        )
        return LayoutInstance(cellID: cellID, name: r.cellName, transform: transform)
    }

    private func convertArrayRef(_ a: IRArrayRef, dbu: Double, cellNameToID: [String: UUID]) -> [LayoutInstance] {
        guard let cellID = cellNameToID[a.cellName] else { return [] }
        guard a.referencePoints.count >= 3 else { return [] }
        let cols = Int(a.columns)
        let rows = Int(a.rows)
        guard cols > 0, rows > 0 else { return [] }

        let origin = a.referencePoints[0]
        let colEnd = a.referencePoints[1]
        let rowEnd = a.referencePoints[2]

        // Column/row spacing vectors in DBU
        let colDX = Double(colEnd.x - origin.x) / Double(cols)
        let colDY = Double(colEnd.y - origin.y) / Double(cols)
        let rowDX = Double(rowEnd.x - origin.x) / Double(rows)
        let rowDY = Double(rowEnd.y - origin.y) / Double(rows)

        let rotation = angleToRotation(a.transform.angle)
        var instances: [LayoutInstance] = []

        for r in 0..<rows {
            for c in 0..<cols {
                let px = Double(origin.x) + Double(c) * colDX + Double(r) * rowDX
                let py = Double(origin.y) + Double(c) * colDY + Double(r) * rowDY
                let pos = LayoutPoint(x: px / dbu, y: py / dbu)
                let transform = LayoutTransform(
                    translation: pos,
                    rotation: rotation,
                    mirrorX: a.transform.mirrorX
                )
                instances.append(LayoutInstance(
                    cellID: cellID,
                    name: "\(a.cellName)[\(r),\(c)]",
                    transform: transform
                ))
            }
        }
        return instances
    }

    // MARK: - Private: Export helpers

    private func convertToIRCell(
        _ cell: LayoutCell,
        dbu: Double,
        reverseLayerMap: [LayoutLayerID: (Int16, Int16)],
        cellIDToName: [UUID: String]
    ) -> IRCell {
        var elements: [IRElement] = []

        for shape in cell.shapes {
            let (layer, datatype) = reverseLayerMap[shape.layer] ?? (0, 0)
            switch shape.geometry {
            case .polygon(let poly):
                var pts = poly.points.map { micronToDBU($0, dbu: dbu) }
                // Close the polygon for GDSII
                if let first = pts.first, pts.last != first {
                    pts.append(first)
                }
                elements.append(.boundary(IRBoundary(
                    layer: layer, datatype: datatype, points: pts, properties: []
                )))
            case .rect(let rect):
                let pts = [
                    micronToDBU(LayoutPoint(x: rect.minX, y: rect.minY), dbu: dbu),
                    micronToDBU(LayoutPoint(x: rect.maxX, y: rect.minY), dbu: dbu),
                    micronToDBU(LayoutPoint(x: rect.maxX, y: rect.maxY), dbu: dbu),
                    micronToDBU(LayoutPoint(x: rect.minX, y: rect.maxY), dbu: dbu),
                    micronToDBU(LayoutPoint(x: rect.minX, y: rect.minY), dbu: dbu),
                ]
                elements.append(.boundary(IRBoundary(
                    layer: layer, datatype: datatype, points: pts, properties: []
                )))
            case .path(let path):
                let irPathType: IRPathType
                switch path.endCap {
                case .truncate: irPathType = .flush
                case .round: irPathType = .round
                case .extend: irPathType = .halfWidthExtend
                }
                elements.append(.path(IRPath(
                    layer: layer, datatype: datatype,
                    pathType: irPathType,
                    width: Int32(path.width * dbu),
                    points: path.points.map { micronToDBU($0, dbu: dbu) },
                    properties: []
                )))
            }
        }

        for label in cell.labels {
            let (layer, texttype) = reverseLayerMap[label.layer] ?? (0, 0)
            elements.append(.text(IRText(
                layer: layer, texttype: texttype,
                transform: .identity,
                position: micronToDBU(label.position, dbu: dbu),
                string: label.text,
                properties: []
            )))
        }

        for instance in cell.instances {
            guard let cellName = cellIDToName[instance.cellID] else { continue }
            let origin = micronToDBU(
                instance.transform.translation,
                dbu: dbu
            )
            let angle = rotationToAngle(instance.transform.rotation)
            elements.append(.cellRef(IRCellRef(
                cellName: cellName,
                origin: origin,
                transform: IRTransform(
                    mirrorX: instance.transform.mirrorX,
                    angle: angle
                ),
                properties: []
            )))
        }

        return IRCell(name: cell.name, elements: elements)
    }

    // MARK: - Coordinate conversion

    private func dbuToMicron(_ p: IRPoint, dbu: Double) -> LayoutPoint {
        LayoutPoint(x: Double(p.x) / dbu, y: Double(p.y) / dbu)
    }

    private func micronToDBU(_ p: LayoutPoint, dbu: Double) -> IRPoint {
        IRPoint(x: Int32(p.x * dbu), y: Int32(p.y * dbu))
    }

    // MARK: - Layer mapping

    private struct LayerKey: Hashable {
        let gdsLayer: Int
        let gdsDatatype: Int
    }

    private func buildLayerMap(tech: LayoutTechDatabase) -> [LayerKey: LayoutLayerID] {
        var map: [LayerKey: LayoutLayerID] = [:]
        for def in tech.layers {
            map[LayerKey(gdsLayer: def.gdsLayer, gdsDatatype: def.gdsDatatype)] = def.id
        }
        return map
    }

    private func buildReverseLayerMap(tech: LayoutTechDatabase) -> [LayoutLayerID: (Int16, Int16)] {
        var map: [LayoutLayerID: (Int16, Int16)] = [:]
        for def in tech.layers {
            map[def.id] = (Int16(def.gdsLayer), Int16(def.gdsDatatype))
        }
        return map
    }

    private func resolveLayer(gdsLayer: Int, gdsDatatype: Int, layerMap: [LayerKey: LayoutLayerID]) -> LayoutLayerID {
        if let id = layerMap[LayerKey(gdsLayer: gdsLayer, gdsDatatype: gdsDatatype)] {
            return id
        }
        // Fallback: create a layer ID from numbers
        return LayoutLayerID(name: "L\(gdsLayer)", purpose: "D\(gdsDatatype)")
    }

    // MARK: - Rotation conversion

    private func angleToRotation(_ angle: Double) -> LayoutRotation {
        let normalized = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        if normalized < 45 || normalized >= 315 { return .deg0 }
        if normalized >= 45 && normalized < 135 { return .deg90 }
        if normalized >= 135 && normalized < 225 { return .deg180 }
        return .deg270
    }

    private func rotationToAngle(_ rotation: LayoutRotation) -> Double {
        switch rotation {
        case .deg0: return 0.0
        case .deg90: return 90.0
        case .deg180: return 180.0
        case .deg270: return 270.0
        }
    }
}
