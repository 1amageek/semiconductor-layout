import Foundation
import LayoutCore
import LayoutTech
import LayoutIR

/// Converts between IRLibrary (GDSII/OASIS intermediate representation)
/// and LayoutDocument (editor-native model).
public struct IRLayoutBridge: Sendable {
    private static let viaDefinitionPropertyAttribute: Int16 = 7301
    private static let viaDefinitionPropertyName = "lsi.viaDefinition"

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

    public func exportLibrary(_ document: LayoutDocument, tech: LayoutTechDatabase) throws -> IRLibrary {
        let dbu = document.units.dbuPerMicron
        let reverseLayerMap = buildReverseLayerMap(tech: tech)

        // Build cell UUID → name mapping
        var cellIDToName: [UUID: String] = [:]
        for cell in document.cells {
            cellIDToName[cell.id] = cell.name
        }

        var irCells: [IRCell] = []
        for cell in document.cells {
            let irCell = try convertToIRCell(cell, dbu: dbu, reverseLayerMap: reverseLayerMap, cellIDToName: cellIDToName)
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
        layerMap: LayerMap,
        cellNameToID: [String: UUID]
    ) -> LayoutCell {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var labels: [LayoutLabel] = []
        var instances: [LayoutInstance] = []

        for element in irCell.elements {
            switch element {
            case .boundary(let b):
                if let via = convertViaBoundary(b, dbu: dbu, layerMap: layerMap) {
                    vias.append(via)
                } else if let shape = convertBoundary(b, dbu: dbu, layerMap: layerMap.ids) {
                    shapes.append(shape)
                }
            case .path(let p):
                if let shape = convertPath(p, dbu: dbu, layerMap: layerMap.ids) {
                    shapes.append(shape)
                }
            case .text(let t):
                if let label = convertText(t, dbu: dbu, layerMap: layerMap.ids) {
                    labels.append(label)
                }
            case .cellRef(let r):
                if let inst = convertCellRef(r, dbu: dbu, cellNameToID: cellNameToID) {
                    instances.append(inst)
                }
            case .arrayRef(let a):
                if let inst = convertArrayRef(a, dbu: dbu, cellNameToID: cellNameToID) {
                    instances.append(inst)
                }
            }
        }

        return LayoutCell(
            id: cellID,
            name: irCell.name,
            shapes: shapes,
            vias: vias,
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
        let transform = LayoutTransform(
            translation: origin,
            rotationDegrees: r.transform.angle,
            magnification: r.transform.magnification,
            mirrorX: r.transform.mirrorX
        )
        return LayoutInstance(cellID: cellID, name: r.cellName, transform: transform)
    }

    private func convertArrayRef(_ a: IRArrayRef, dbu: Double, cellNameToID: [String: UUID]) -> LayoutInstance? {
        guard let cellID = cellNameToID[a.cellName] else { return nil }
        guard a.referencePoints.count >= 3 else { return nil }
        let cols = Int(a.columns)
        let rows = Int(a.rows)
        guard cols > 0, rows > 0 else { return nil }

        let origin = a.referencePoints[0]
        let colEnd = a.referencePoints[1]
        let rowEnd = a.referencePoints[2]

        let colDX = Double(colEnd.x - origin.x) / Double(cols)
        let colDY = Double(colEnd.y - origin.y) / Double(cols)
        let rowDX = Double(rowEnd.x - origin.x) / Double(rows)
        let rowDY = Double(rowEnd.y - origin.y) / Double(rows)

        let transform = LayoutTransform(
            translation: dbuToMicron(origin, dbu: dbu),
            rotationDegrees: a.transform.angle,
            magnification: a.transform.magnification,
            mirrorX: a.transform.mirrorX
        )
        return LayoutInstance(
            cellID: cellID,
            name: a.cellName,
            transform: transform,
            repetition: LayoutRepetition(
                columns: cols,
                rows: rows,
                columnStep: LayoutPoint(x: colDX / dbu, y: colDY / dbu),
                rowStep: LayoutPoint(x: rowDX / dbu, y: rowDY / dbu)
            )
        )
    }

    private func convertViaBoundary(_ boundary: IRBoundary, dbu: Double, layerMap: LayerMap) -> LayoutVia? {
        guard let viaDefinitionID = viaDefinitionID(from: boundary.properties) else {
            return nil
        }
        guard let definition = layerMap.tech.viaDefinition(for: viaDefinitionID) else {
            return nil
        }
        guard layerMap.ids[LayerKey(gdsLayer: Int(boundary.layer), gdsDatatype: Int(boundary.datatype))] == definition.cutLayer else {
            return nil
        }
        guard let rect = rectangle(from: boundary.points, dbu: dbu) else {
            return nil
        }
        guard approximatelyEqual(rect.size.width, definition.cutSize.width, tolerance: 1 / dbu),
              approximatelyEqual(rect.size.height, definition.cutSize.height, tolerance: 1 / dbu) else {
            return nil
        }
        return LayoutVia(viaDefinitionID: viaDefinitionID, position: rect.center)
    }

    // MARK: - Private: Export helpers

    private func convertToIRCell(
        _ cell: LayoutCell,
        dbu: Double,
        reverseLayerMap: ReverseLayerMap,
        cellIDToName: [UUID: String]
    ) throws -> IRCell {
        var elements: [IRElement] = []

        for shape in cell.shapes {
            let (layer, datatype) = reverseLayerMap.ids[shape.layer] ?? (0, 0)
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

        for via in cell.vias {
            guard let viaDefinition = reverseLayerMap.tech.viaDefinition(for: via.viaDefinitionID) else {
                continue
            }
            guard let (layer, datatype) = reverseLayerMap.ids[viaDefinition.cutLayer] else {
                continue
            }
            elements.append(.boundary(IRBoundary(
                layer: layer,
                datatype: datatype,
                points: viaCutBoundaryPoints(via: via, definition: viaDefinition, dbu: dbu),
                properties: [
                    IRProperty(
                        attribute: Self.viaDefinitionPropertyAttribute,
                        value: "\(Self.viaDefinitionPropertyName)=\(via.viaDefinitionID)"
                    )
                ]
            )))
        }

        for label in cell.labels {
            let (layer, texttype) = reverseLayerMap.ids[label.layer] ?? (0, 0)
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
            let transform = IRTransform(
                mirrorX: instance.transform.mirrorX,
                magnification: instance.transform.magnification,
                angle: instance.transform.rotationDegrees
            )
            if let repetition = instance.repetition,
               repetition.columns > 1 || repetition.rows > 1 {
                // GDSII COLROW is a signed 16-bit record; a wider count
                // cannot be represented, so refuse the export instead of
                // trapping or silently truncating the array.
                guard repetition.columns <= Int(Int16.max),
                      repetition.rows <= Int(Int16.max) else {
                    throw LayoutIOError.conversionFailed(
                        "Instance '\(instance.name)' in cell '\(cell.name)' repeats "
                            + "\(repetition.columns)x\(repetition.rows); GDSII AREF "
                            + "supports at most \(Int16.max) columns/rows. "
                            + "Explode the array before exporting."
                    )
                }
                let colEnd = micronToDBU(
                    LayoutPoint(
                        x: instance.transform.translation.x + repetition.columnStep.x * Double(repetition.columns),
                        y: instance.transform.translation.y + repetition.columnStep.y * Double(repetition.columns)
                    ),
                    dbu: dbu
                )
                let rowEnd = micronToDBU(
                    LayoutPoint(
                        x: instance.transform.translation.x + repetition.rowStep.x * Double(repetition.rows),
                        y: instance.transform.translation.y + repetition.rowStep.y * Double(repetition.rows)
                    ),
                    dbu: dbu
                )
                elements.append(.arrayRef(IRArrayRef(
                    cellName: cellName,
                    transform: transform,
                    columns: Int16(repetition.columns),
                    rows: Int16(repetition.rows),
                    referencePoints: [origin, colEnd, rowEnd],
                    properties: []
                )))
            } else {
                elements.append(.cellRef(IRCellRef(
                    cellName: cellName,
                    origin: origin,
                    transform: transform,
                    properties: []
                )))
            }
        }

        return IRCell(name: cell.name, elements: elements)
    }

    private func viaCutBoundaryPoints(via: LayoutVia, definition: LayoutViaDefinition, dbu: Double) -> [IRPoint] {
        let halfWidth = definition.cutSize.width / 2
        let halfHeight = definition.cutSize.height / 2
        let rect = LayoutRect(
            origin: LayoutPoint(x: via.position.x - halfWidth, y: via.position.y - halfHeight),
            size: definition.cutSize
        )
        return [
            micronToDBU(LayoutPoint(x: rect.minX, y: rect.minY), dbu: dbu),
            micronToDBU(LayoutPoint(x: rect.maxX, y: rect.minY), dbu: dbu),
            micronToDBU(LayoutPoint(x: rect.maxX, y: rect.maxY), dbu: dbu),
            micronToDBU(LayoutPoint(x: rect.minX, y: rect.maxY), dbu: dbu),
            micronToDBU(LayoutPoint(x: rect.minX, y: rect.minY), dbu: dbu),
        ]
    }

    private func rectangle(from points: [IRPoint], dbu: Double) -> LayoutRect? {
        var layoutPoints = points.map { dbuToMicron($0, dbu: dbu) }
        if layoutPoints.count > 1 && layoutPoints.first == layoutPoints.last {
            layoutPoints.removeLast()
        }
        guard layoutPoints.count == 4 else { return nil }
        let xs = Set(layoutPoints.map(\.x))
        let ys = Set(layoutPoints.map(\.y))
        guard xs.count == 2, ys.count == 2 else { return nil }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        guard maxX > minX, maxY > minY else { return nil }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) <= max(tolerance, 1e-12)
    }

    private func viaDefinitionID(from properties: [IRProperty]) -> String? {
        for property in properties {
            if property.attribute == Self.viaDefinitionPropertyAttribute {
                return propertyValue(property.value, for: Self.viaDefinitionPropertyName) ?? property.value
            }
            if let value = propertyValue(property.value, for: Self.viaDefinitionPropertyName) {
                return value
            }
        }
        return nil
    }

    private func propertyValue(_ rawValue: String, for key: String) -> String? {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == key else { return nil }
        return String(parts[1])
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

    private struct LayerMap {
        let ids: [LayerKey: LayoutLayerID]
        let tech: LayoutTechDatabase
    }

    private struct ReverseLayerMap {
        let ids: [LayoutLayerID: (Int16, Int16)]
        let tech: LayoutTechDatabase
    }

    private func buildLayerMap(tech: LayoutTechDatabase) -> LayerMap {
        var map: [LayerKey: LayoutLayerID] = [:]
        for def in tech.layers {
            map[LayerKey(gdsLayer: def.gdsLayer, gdsDatatype: def.gdsDatatype)] = def.id
        }
        return LayerMap(ids: map, tech: tech)
    }

    private func buildReverseLayerMap(tech: LayoutTechDatabase) -> ReverseLayerMap {
        var map: [LayoutLayerID: (Int16, Int16)] = [:]
        for def in tech.layers {
            map[def.id] = (Int16(def.gdsLayer), Int16(def.gdsDatatype))
        }
        return ReverseLayerMap(ids: map, tech: tech)
    }

    private func resolveLayer(gdsLayer: Int, gdsDatatype: Int, layerMap: [LayerKey: LayoutLayerID]) -> LayoutLayerID {
        if let id = layerMap[LayerKey(gdsLayer: gdsLayer, gdsDatatype: gdsDatatype)] {
            return id
        }
        // Fallback: create a layer ID from numbers
        return LayoutLayerID(name: "L\(gdsLayer)", purpose: "D\(gdsDatatype)")
    }

}
