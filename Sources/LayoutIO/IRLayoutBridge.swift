import Foundation
import LayoutCore
import LayoutTech
import LayoutIR

/// Converts between IRLibrary (GDSII/OASIS intermediate representation)
/// and LayoutDocument (editor-native model).
public struct IRLayoutBridge: Sendable {
    private static let viaDefinitionPropertyAttribute: Int16 = 7301
    private static let viaDefinitionPropertyName = "lsi.viaDefinition"
    private static let defComponentNamePropertyName = "def.component.name"
    private static let defNetCountPropertyName = "def.net.count"
    private static let defNetPropertyPrefix = "def.net"
    private static let defSpecialNetCountPropertyName = "def.specialNet.count"
    private static let defSpecialNetPropertyPrefix = "def.specialNet"
    private static let defRouteKindPropertyName = "def.route.kind"
    private static let defRouteNetNamePropertyName = "def.route.netName"
    private static let defRouteStatusPropertyName = "def.route.status"
    private static let defRouteLayerNamePropertyName = "def.route.layerName"
    private static let defRouteWidthPropertyName = "def.route.width"
    private static let defRouteViaNamePropertyName = "def.route.viaName"
    private static let defRouteSpecialPointsPropertyName = "def.route.specialPoints"

    public init() {}

    // MARK: - Import: IRLibrary → LayoutDocument

    @available(*, deprecated, message: "Use checkedImportLibrary for design, signoff, and agent-facing import. This legacy importer preserves permissive preview behavior.")
    public func importLibrary(_ library: IRLibrary, tech: LayoutTechDatabase) -> LayoutDocument {
        let dbu = library.units.dbuPerMicron
        let layerMap = buildLayerMap(tech: tech)
        let cellNameToID = buildCellNameMap(for: library)

        var cells: [LayoutCell] = []
        for irCell in library.cells {
            guard let cellID = cellNameToID[irCell.name] else { continue }
            let cell = convertCell(irCell, cellID: cellID, dbu: dbu, layerMap: layerMap, cellNameToID: cellNameToID)
            cells.append(cell)
        }

        return makeDocument(name: library.name, dbu: dbu, cells: cells)
    }

    public func checkedImportLibrary(_ library: IRLibrary, tech: LayoutTechDatabase) throws -> LayoutDocument {
        let dbu = library.units.dbuPerMicron
        let layerMap = buildLayerMap(tech: tech)
        try validateUniqueCellNames(in: library)
        let cellNameToID = buildCellNameMap(for: library)
        try validateImportLibrary(library, layerMap: layerMap, cellNameToID: cellNameToID)

        var cells: [LayoutCell] = []
        for irCell in library.cells {
            guard let cellID = cellNameToID[irCell.name] else {
                throw LayoutIOError.conversionFailed("Missing cell identifier for imported cell '\(irCell.name)'")
            }
            let cell = convertCell(irCell, cellID: cellID, dbu: dbu, layerMap: layerMap, cellNameToID: cellNameToID)
            cells.append(cell)
        }

        return makeDocument(name: library.name, dbu: dbu, cells: cells)
    }

    private func buildCellNameMap(for library: IRLibrary) -> [String: UUID] {
        var cellNameToID: [String: UUID] = [:]
        for irCell in library.cells {
            cellNameToID[irCell.name] = UUID()
        }
        return cellNameToID
    }

    private func makeDocument(name: String, dbu: Double, cells: [LayoutCell]) -> LayoutDocument {
        // GDS carries no explicit top cell; the top is the cell that no
        // other cell references. Multiple roots resolve to the first in
        // library order, deterministically.
        let referencedCellIDs = Set(cells.flatMap { $0.instances.map(\.cellID) })
        let topCellID = cells.first { !referencedCellIDs.contains($0.id) }?.id ?? cells.first?.id
        return LayoutDocument(
            name: name,
            units: LayoutUnits(dbuPerMicron: dbu),
            cells: cells,
            topCellID: topCellID
        )
    }

    // MARK: - Export: LayoutDocument → IRLibrary

    public func exportLibrary(
        _ document: LayoutDocument,
        tech: LayoutTechDatabase,
        includeDEFRouteMetadata: Bool = false
    ) throws -> IRLibrary {
        let dbu = document.units.dbuPerMicron
        let reverseLayerMap = buildReverseLayerMap(tech: tech)

        // Build cell UUID → name mapping
        var cellIDToName: [UUID: String] = [:]
        for cell in document.cells {
            cellIDToName[cell.id] = cell.name
        }

        var irCells: [IRCell] = []
        for cell in document.cells {
            try validateUniqueCellName(cell, in: cellIDToName)
            let irCell = try convertToIRCell(
                cell,
                dbu: dbu,
                reverseLayerMap: reverseLayerMap,
                cellIDToName: cellIDToName,
                includeDEFRouteMetadata: includeDEFRouteMetadata
            )
            irCells.append(irCell)
        }

        return IRLibrary(
            name: document.name,
            units: IRUnits(dbuPerMicron: dbu),
            cells: irCells
        )
    }

    // MARK: - Private: Import helpers

    private func validateUniqueCellNames(in library: IRLibrary) throws {
        var seen: Set<String> = []
        for cell in library.cells {
            guard seen.insert(cell.name).inserted else {
                throw LayoutIOError.conversionFailed("Duplicate imported cell name '\(cell.name)'")
            }
        }
    }

    private func validateImportLibrary(
        _ library: IRLibrary,
        layerMap: LayerMap,
        cellNameToID: [String: UUID]
    ) throws {
        for cell in library.cells {
            for element in cell.elements {
                switch element {
                case .boundary(let boundary):
                    try requireMappedLayer(
                        gdsLayer: Int(boundary.layer),
                        gdsDatatype: Int(boundary.datatype),
                        layerMap: layerMap.ids,
                        context: "boundary in cell '\(cell.name)'"
                    )
                    var points = boundary.points
                    if points.count > 1 && points.first == points.last {
                        points.removeLast()
                    }
                    guard points.count >= 3 else {
                        throw LayoutIOError.conversionFailed("Boundary in cell '\(cell.name)' has fewer than 3 points")
                    }
                case .path(let path):
                    try requireMappedRouteLayer(path, layerMap: layerMap, context: "path in cell '\(cell.name)'")
                    guard path.points.count >= 2, path.width > 0 else {
                        throw LayoutIOError.conversionFailed("Path in cell '\(cell.name)' has invalid geometry")
                    }
                    try validateRouteViaReferences(
                        path,
                        layerMap: layerMap,
                        context: "path in cell '\(cell.name)'"
                    )
                case .text(let text):
                    try requireMappedLayer(
                        gdsLayer: Int(text.layer),
                        gdsDatatype: Int(text.texttype),
                        layerMap: layerMap.ids,
                        context: "text in cell '\(cell.name)'"
                    )
                case .cellRef(let reference):
                    guard cellNameToID[reference.cellName] != nil else {
                        throw LayoutIOError.conversionFailed(
                            "Cell reference '\(reference.cellName)' in cell '\(cell.name)' has no target cell"
                        )
                    }
                case .arrayRef(let reference):
                    guard cellNameToID[reference.cellName] != nil else {
                        throw LayoutIOError.conversionFailed(
                            "Array reference '\(reference.cellName)' in cell '\(cell.name)' has no target cell"
                        )
                    }
                    guard reference.columns > 0, reference.rows > 0, reference.referencePoints.count >= 3 else {
                        throw LayoutIOError.conversionFailed(
                            "Array reference '\(reference.cellName)' in cell '\(cell.name)' has invalid array geometry"
                        )
                    }
                }
            }
        }
    }

    private func requireMappedRouteLayer(_ path: IRPath, layerMap: LayerMap, context: String) throws {
        let properties = layoutProperties(from: path.properties)
        if let layerName = properties[Self.defRouteLayerNamePropertyName] {
            guard layerMap.idsByDEFName[normalizedDEFName(layerName)] != nil else {
                throw LayoutIOError.conversionFailed(
                    "Unmapped DEF route layer '\(layerName)' for \(context)"
                )
            }
            return
        }
        try requireMappedLayer(
            gdsLayer: Int(path.layer),
            gdsDatatype: Int(path.datatype),
            layerMap: layerMap.ids,
            context: context
        )
    }

    private func requireMappedLayer(
        gdsLayer: Int,
        gdsDatatype: Int,
        layerMap: [LayerKey: LayoutLayerID],
        context: String
    ) throws {
        guard layerMap[LayerKey(gdsLayer: gdsLayer, gdsDatatype: gdsDatatype)] != nil else {
            throw LayoutIOError.conversionFailed(
                "Unmapped GDS layer/datatype (\(gdsLayer),\(gdsDatatype)) for \(context)"
            )
        }
    }

    private func validateRouteViaReferences(_ path: IRPath, layerMap: LayerMap, context: String) throws {
        let properties = layoutProperties(from: path.properties)
        if let viaName = properties[Self.defRouteViaNamePropertyName] {
            try requireRouteViaDefinition(viaName, layerMap: layerMap, context: context)
            guard !path.points.isEmpty else {
                throw LayoutIOError.conversionFailed("DEF route via '\(viaName)' for \(context) has no placement point")
            }
        }

        guard properties[Self.defRouteKindPropertyName] == "specialNet",
              let encodedPoints = properties[Self.defRouteSpecialPointsPropertyName] else {
            return
        }

        var previousPoint: IRPoint?
        for point in decodeSpecialRoutePoints(encodedPoints) {
            if let viaName = point.viaName {
                try requireRouteViaDefinition(viaName, layerMap: layerMap, context: context)
                guard previousPoint != nil else {
                    throw LayoutIOError.conversionFailed(
                        "DEF special route via '\(viaName)' for \(context) has no preceding placement point"
                    )
                }
                continue
            }
            previousPoint = point.resolved(previous: previousPoint)
        }
    }

    private func requireRouteViaDefinition(_ viaName: String, layerMap: LayerMap, context: String) throws {
        let trimmedViaName = viaName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedViaName.isEmpty else {
            throw LayoutIOError.conversionFailed("Blank DEF route via name for \(context)")
        }
        guard layerMap.tech.viaDefinition(for: trimmedViaName) != nil else {
            throw LayoutIOError.conversionFailed(
                "DEF route via '\(trimmedViaName)' for \(context) has no technology via definition"
            )
        }
    }

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
        let cellProperties = layoutProperties(from: irCell.properties)
        let nets = layoutNets(from: cellProperties, elements: irCell.elements)
        let netIDByName = Dictionary(uniqueKeysWithValues: nets.map { ($0.name, $0.id) })

        for element in irCell.elements {
            switch element {
            case .boundary(let b):
                if let via = convertViaBoundary(b, dbu: dbu, layerMap: layerMap) {
                    vias.append(via)
                } else if let shape = convertBoundary(
                    b,
                    dbu: dbu,
                    layerMap: layerMap,
                    netIDByName: netIDByName
                ) {
                    shapes.append(shape)
                }
            case .path(let p):
                if let shape = convertPath(p, dbu: dbu, layerMap: layerMap, netIDByName: netIDByName) {
                    shapes.append(shape)
                }
                vias.append(contentsOf: convertRouteVias(
                    p,
                    dbu: dbu,
                    layerMap: layerMap,
                    netIDByName: netIDByName
                ))
            case .text(let t):
                if let label = convertText(t, dbu: dbu, layerMap: layerMap.ids, netIDByName: netIDByName) {
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
            instances: instances,
            nets: nets,
            properties: cellProperties
        )
    }

    private func convertBoundary(
        _ b: IRBoundary,
        dbu: Double,
        layerMap: LayerMap,
        netIDByName: [String: UUID]
    ) -> LayoutShape? {
        let properties = layoutProperties(from: b.properties)
        let layerID = resolveLayer(
            gdsLayer: Int(b.layer),
            gdsDatatype: Int(b.datatype),
            layerMap: layerMap.ids
        )
        // Remove closing point (GDSII requires first == last, LayoutPolygon does not)
        var pts = b.points.map { dbuToMicron($0, dbu: dbu) }
        if pts.count > 1 && pts.first == pts.last {
            pts.removeLast()
        }
        guard pts.count >= 3 else { return nil }
        return LayoutShape(
            layer: layerID,
            netID: routeNetID(from: properties, netIDByName: netIDByName),
            geometry: .polygon(LayoutPolygon(points: pts)),
            properties: properties
        )
    }

    private func convertPath(
        _ p: IRPath,
        dbu: Double,
        layerMap: LayerMap,
        netIDByName: [String: UUID]
    ) -> LayoutShape? {
        let properties = layoutProperties(from: p.properties)
        let layerID = routeLayerID(
            properties: properties,
            gdsLayer: Int(p.layer),
            gdsDatatype: Int(p.datatype),
            layerMap: layerMap
        )
        let pts = p.points.map { dbuToMicron($0, dbu: dbu) }
        let width = routePathWidth(
            rawWidth: Double(p.width) / dbu,
            properties: properties,
            layerID: layerID,
            tech: layerMap.tech
        )
        guard pts.count >= 2 && width > 0 else { return nil }
        let endCap: LayoutPathEndCap
        switch p.pathType {
        case .flush: endCap = .truncate
        case .round: endCap = .round
        case .halfWidthExtend, .customExtension: endCap = .extend
        }
        return LayoutShape(
            layer: layerID,
            netID: routeNetID(from: properties, netIDByName: netIDByName),
            geometry: .path(LayoutPath(points: pts, width: width, endCap: endCap)),
            properties: properties
        )
    }

    private func routePathWidth(
        rawWidth: Double,
        properties: [String: String],
        layerID: LayoutLayerID,
        tech: LayoutTechDatabase
    ) -> Double {
        guard properties[Self.defRouteKindPropertyName] == "net",
              properties[Self.defRouteWidthPropertyName] == nil,
              let minimumWidth = tech.ruleSet(for: layerID)?.minWidth else {
            return rawWidth
        }
        return max(rawWidth, minimumWidth)
    }

    private func convertRouteVias(
        _ path: IRPath,
        dbu: Double,
        layerMap: LayerMap,
        netIDByName: [String: UUID]
    ) -> [LayoutVia] {
        let properties = layoutProperties(from: path.properties)
        guard let netID = routeNetID(from: properties, netIDByName: netIDByName) else {
            return []
        }
        if let viaName = properties[Self.defRouteViaNamePropertyName],
           let via = routeVia(
            named: viaName,
            at: path.points.last,
            dbu: dbu,
            layerMap: layerMap,
            netID: netID
           ) {
            return [via]
        }
        guard properties[Self.defRouteKindPropertyName] == "specialNet",
              let encodedPoints = properties[Self.defRouteSpecialPointsPropertyName] else {
            return []
        }
        var result: [LayoutVia] = []
        var previousPoint: IRPoint?
        for point in decodeSpecialRoutePoints(encodedPoints) {
            if let viaName = point.viaName {
                if let via = routeVia(
                    named: viaName,
                    at: previousPoint,
                    dbu: dbu,
                    layerMap: layerMap,
                    netID: netID
                ) {
                    result.append(via)
                }
                continue
            }
            let resolved = point.resolved(previous: previousPoint)
            previousPoint = resolved
        }
        return result
    }

    private func routeVia(
        named viaName: String,
        at point: IRPoint?,
        dbu: Double,
        layerMap: LayerMap,
        netID: UUID
    ) -> LayoutVia? {
        guard let point,
              layerMap.tech.viaDefinition(for: viaName) != nil else {
            return nil
        }
        return LayoutVia(
            viaDefinitionID: viaName,
            position: dbuToMicron(point, dbu: dbu),
            netID: netID
        )
    }

    private func convertText(
        _ t: IRText,
        dbu: Double,
        layerMap: [LayerKey: LayoutLayerID],
        netIDByName: [String: UUID]
    ) -> LayoutLabel? {
        let layerID = resolveLayer(gdsLayer: Int(t.layer), gdsDatatype: Int(t.texttype), layerMap: layerMap)
        let pos = dbuToMicron(t.position, dbu: dbu)
        return LayoutLabel(
            text: t.string,
            position: pos,
            layer: layerID,
            netID: propertyValue(t.properties, for: "def.pin.netName").flatMap { netIDByName[$0] }
        )
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
        let instanceName = propertyValue(r.properties, for: Self.defComponentNamePropertyName) ?? r.cellName
        return LayoutInstance(cellID: cellID, name: instanceName, transform: transform)
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
            name: propertyValue(a.properties, for: Self.defComponentNamePropertyName) ?? a.cellName,
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
        cellIDToName: [UUID: String],
        includeDEFRouteMetadata: Bool
    ) throws -> IRCell {
        var elements: [IRElement] = []
        let netNameByID = Dictionary(uniqueKeysWithValues: cell.nets.map { ($0.id, $0.name) })

        for shape in cell.shapes {
            let (layer, datatype) = try exportedLayerPair(shape.layer, reverseLayerMap: reverseLayerMap, context: "shape '\(shape.id)' in cell '\(cell.name)'")
            let shapeProperties = routedShapeProperties(
                shape,
                layerID: shape.layer,
                reverseLayerMap: reverseLayerMap,
                netNameByID: netNameByID,
                includeDEFRouteMetadata: includeDEFRouteMetadata
            )
            switch shape.geometry {
            case .polygon(let poly):
                var pts = poly.points.map { micronToDBU($0, dbu: dbu) }
                // Close the polygon for GDSII
                if let first = pts.first, pts.last != first {
                    pts.append(first)
                }
                elements.append(.boundary(IRBoundary(
                    layer: layer,
                    datatype: datatype,
                    points: pts,
                    properties: irProperties(from: shapeProperties)
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
                    layer: layer,
                    datatype: datatype,
                    points: pts,
                    properties: irProperties(from: shapeProperties)
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
                    properties: irProperties(from: shapeProperties)
                )))
            }
        }

        for via in cell.vias {
            guard let viaDefinition = reverseLayerMap.tech.viaDefinition(for: via.viaDefinitionID) else {
                throw LayoutIOError.conversionFailed(
                    "Via '\(via.id)' in cell '\(cell.name)' references unknown via definition '\(via.viaDefinitionID)'"
                )
            }
            guard let (layer, datatype) = reverseLayerMap.ids[viaDefinition.cutLayer] else {
                throw LayoutIOError.conversionFailed(
                    "Via definition '\(via.viaDefinitionID)' cut layer '\(viaDefinition.cutLayer)' has no GDS mapping"
                )
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
            let (layer, texttype) = try exportedLayerPair(label.layer, reverseLayerMap: reverseLayerMap, context: "label '\(label.id)' in cell '\(cell.name)'")
            elements.append(.text(IRText(
                layer: layer, texttype: texttype,
                transform: .identity,
                position: micronToDBU(label.position, dbu: dbu),
                string: label.text,
                properties: []
            )))
        }

        for instance in cell.instances {
            guard let cellName = cellIDToName[instance.cellID] else {
                throw LayoutIOError.conversionFailed(
                    "Instance '\(instance.name)' in cell '\(cell.name)' references missing cell \(instance.cellID)"
                )
            }
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
                    properties: instanceProperties(instance)
                )))
            } else {
                elements.append(.cellRef(IRCellRef(
                    cellName: cellName,
                    origin: origin,
                    transform: transform,
                    properties: instanceProperties(instance)
                )))
            }
        }

        return IRCell(
            name: cell.name,
            elements: elements,
            properties: irProperties(from: cellPropertiesForExport(
                cell,
                includeDEFRouteMetadata: includeDEFRouteMetadata
            ))
        )
    }

    private func validateUniqueCellName(_ cell: LayoutCell, in cellIDToName: [UUID: String]) throws {
        let duplicates = cellIDToName.values.filter { $0 == cell.name }.count
        guard duplicates == 1 else {
            throw LayoutIOError.conversionFailed("Duplicate document cell name '\(cell.name)'")
        }
    }

    private func exportedLayerPair(
        _ layerID: LayoutLayerID,
        reverseLayerMap: ReverseLayerMap,
        context: String
    ) throws -> (Int16, Int16) {
        guard let pair = reverseLayerMap.ids[layerID] else {
            throw LayoutIOError.conversionFailed("Layer '\(layerID)' for \(context) has no GDS mapping")
        }
        return pair
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

    private func layoutNets(from properties: [String: String], elements: [IRElement]) -> [LayoutNet] {
        var names: [String] = []
        appendIndexedNetNames(
            countKey: Self.defNetCountPropertyName,
            prefix: Self.defNetPropertyPrefix,
            properties: properties,
            names: &names
        )
        appendIndexedNetNames(
            countKey: Self.defSpecialNetCountPropertyName,
            prefix: Self.defSpecialNetPropertyPrefix,
            properties: properties,
            names: &names
        )
        for element in elements {
            if case .path(let path) = element,
               let netName = propertyValue(path.properties, for: Self.defRouteNetNamePropertyName),
               !names.contains(netName) {
                names.append(netName)
            }
        }
        return names.map { LayoutNet(name: $0) }
    }

    private func appendIndexedNetNames(
        countKey: String,
        prefix: String,
        properties: [String: String],
        names: inout [String]
    ) {
        let count = properties[countKey].flatMap(Int.init) ?? 0
        for index in 0..<count {
            guard let name = properties["\(prefix).\(index).name"], !names.contains(name) else {
                continue
            }
            names.append(name)
        }
    }

    private func routeNetID(from properties: [String: String], netIDByName: [String: UUID]) -> UUID? {
        guard let netName = properties[Self.defRouteNetNamePropertyName] else {
            return nil
        }
        return netIDByName[netName]
    }

    private func routeLayerID(
        properties: [String: String],
        gdsLayer: Int,
        gdsDatatype: Int,
        layerMap: LayerMap
    ) -> LayoutLayerID {
        if let layerName = properties[Self.defRouteLayerNamePropertyName],
           let layerID = layerMap.idsByDEFName[normalizedDEFName(layerName)] {
            return layerID
        }
        return resolveLayer(gdsLayer: gdsLayer, gdsDatatype: gdsDatatype, layerMap: layerMap.ids)
    }

    private func routedShapeProperties(
        _ shape: LayoutShape,
        layerID: LayoutLayerID,
        reverseLayerMap: ReverseLayerMap,
        netNameByID: [UUID: String],
        includeDEFRouteMetadata: Bool
    ) -> [String: String] {
        var properties = shape.properties
        guard includeDEFRouteMetadata else {
            return properties
        }
        guard case .path = shape.geometry, let netID = shape.netID, let netName = netNameByID[netID] else {
            return properties
        }
        if properties[Self.defRouteKindPropertyName] == nil {
            properties[Self.defRouteKindPropertyName] = "net"
        }
        if properties[Self.defRouteNetNamePropertyName] == nil {
            properties[Self.defRouteNetNamePropertyName] = netName
        }
        if properties[Self.defRouteStatusPropertyName] == nil {
            properties[Self.defRouteStatusPropertyName] = "ROUTED"
        }
        if properties[Self.defRouteLayerNamePropertyName] == nil {
            properties[Self.defRouteLayerNamePropertyName] = defLayerName(for: layerID, reverseLayerMap: reverseLayerMap)
        }
        return properties
    }

    private func defLayerName(for layerID: LayoutLayerID, reverseLayerMap: ReverseLayerMap) -> String {
        reverseLayerMap.tech.layerDefinition(for: layerID)?.id.name ?? layerID.name
    }

    private func cellPropertiesForExport(_ cell: LayoutCell, includeDEFRouteMetadata: Bool) -> [String: String] {
        var properties = cell.properties
        guard includeDEFRouteMetadata,
              properties[Self.defNetCountPropertyName] == nil,
              properties[Self.defSpecialNetCountPropertyName] == nil,
              !cell.nets.isEmpty else {
            return properties
        }
        properties[Self.defNetCountPropertyName] = String(cell.nets.count)
        for (index, net) in cell.nets.enumerated() {
            properties["\(Self.defNetPropertyPrefix).\(index).name"] = net.name
        }
        return properties
    }

    private func propertyValue(_ rawValue: String, for key: String) -> String? {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == key else { return nil }
        return String(parts[1])
    }

    private func propertyValue(_ properties: [IRProperty], for key: String) -> String? {
        for property in properties {
            if let value = propertyValue(property.value, for: key) {
                return value
            }
        }
        return nil
    }

    private func layoutProperties(from properties: [IRProperty]) -> [String: String] {
        var result: [String: String] = [:]
        for property in properties {
            if let parsed = propertyKeyValue(property.value) {
                result[parsed.key] = parsed.value
            } else {
                result[uniquePropertyKey("property.\(property.attribute)", in: result)] = property.value
            }
        }
        return result
    }

    private func irProperties(from properties: [String: String]) -> [IRProperty] {
        properties.keys.sorted().map { key in
            IRProperty(attribute: 0, value: "\(key)=\(properties[key] ?? "")")
        }
    }

    private func decodeSpecialRoutePoints(_ rawValue: String) -> [DecodedSpecialRoutePoint] {
        guard !rawValue.isEmpty else { return [] }
        return rawValue.split(separator: "|", omittingEmptySubsequences: false).map { item in
            let parts = item.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let x = parts.count > 0 && parts[0] != "*" ? Int32(parts[0]) : nil
            let y = parts.count > 1 && parts[1] != "*" ? Int32(parts[1]) : nil
            let viaName = parts.count > 3 && parts[3] != "*" ? unescape(parts[3]) : nil
            return DecodedSpecialRoutePoint(x: x, y: y, viaName: viaName)
        }
    }

    private struct DecodedSpecialRoutePoint {
        let x: Int32?
        let y: Int32?
        let viaName: String?

        func resolved(previous: IRPoint?) -> IRPoint {
            IRPoint(
                x: x ?? previous?.x ?? 0,
                y: y ?? previous?.y ?? 0
            )
        }
    }

    private func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%2C", with: ",")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%25", with: "%")
    }

    private func instanceProperties(_ instance: LayoutInstance) -> [IRProperty] {
        [
            IRProperty(attribute: 0, value: "\(Self.defComponentNamePropertyName)=\(instance.name)")
        ]
    }

    private func propertyKeyValue(_ rawValue: String) -> (key: String, value: String)? {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func uniquePropertyKey(_ base: String, in properties: [String: String]) -> String {
        if properties[base] == nil {
            return base
        }
        var index = 1
        while properties["\(base).\(index)"] != nil {
            index += 1
        }
        return "\(base).\(index)"
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
        let idsByDEFName: [String: LayoutLayerID]
        let tech: LayoutTechDatabase
    }

    private struct ReverseLayerMap {
        let ids: [LayoutLayerID: (Int16, Int16)]
        let tech: LayoutTechDatabase
    }

    private func buildLayerMap(tech: LayoutTechDatabase) -> LayerMap {
        var map: [LayerKey: LayoutLayerID] = [:]
        var names: [String: LayoutLayerID] = [:]
        for def in tech.layers {
            map[LayerKey(gdsLayer: def.gdsLayer, gdsDatatype: def.gdsDatatype)] = def.id
            names[normalizedDEFName(def.id.name)] = def.id
            names[normalizedDEFName(def.displayName)] = def.id
        }
        return LayerMap(ids: map, idsByDEFName: names, tech: tech)
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

    private func normalizedDEFName(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

}
