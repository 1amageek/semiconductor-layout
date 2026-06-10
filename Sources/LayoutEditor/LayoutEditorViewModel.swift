import SwiftUI
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIO
import LayoutIR
import MaskGeometry

@Observable
@MainActor
public final class LayoutEditorViewModel {
    public var editor: LayoutDocumentEditor
    public var tech: LayoutTechDatabase
    public var tool: LayoutTool = .select
    public var activeCellID: UUID?
    public var activeLayer: LayoutLayerID
    public var activeViaID: String
    public var zoom: CGFloat = 1.0
    public var offset: CGPoint = .zero
    public var canvasSize: CGSize = .zero
    public var gridSize: Double
    public var selectedShapeIDs: Set<UUID> = []
    public var selectedInstanceID: UUID?
    public var highlightedInstanceIDs: Set<UUID> = []
    public var violations: [LayoutViolation] = []
    public var lastError: String?
    public var hiddenLayers: Set<LayoutLayerID> = []
    public var cellNavigationPath: [UUID] = []

    // MARK: - Tool Options

    /// Path width for the path tool. Defaults to minimum width of active layer or tech grid.
    public var pathWidth: Double = 0.1
    /// Path end-cap style.
    public var pathEndCap: LayoutPathEndCap = .extend
    /// Angle constraint mode for drawing operations.
    public var angleConstraint: LayoutAngleConstraint = .manhattan

    // MARK: - Rulers

    public var rulers: [LayoutRuler] = []
    private var cellBackStack: [CellNavigationState] = []

    private struct CellNavigationState {
        var activeCellID: UUID?
        var path: [UUID]
    }

    public init(tech: LayoutTechDatabase = .standard()) {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "Layout", cells: [cell], topCellID: cell.id)
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = cell.id
        self.tech = tech
        self.gridSize = tech.grid
        self.activeLayer = tech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = tech.vias.first?.id ?? "VIA1"
        self.pathWidth = defaultPathWidth(for: tech)
        self.cellNavigationPath = [cell.id]
    }

    public init(document: LayoutDocument, tech: LayoutTechDatabase) {
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = document.topCellID ?? document.cells.first?.id
        self.tech = tech
        self.gridSize = tech.grid
        self.activeLayer = tech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = tech.vias.first?.id ?? "VIA1"
        self.pathWidth = defaultPathWidth(for: tech)
        self.cellNavigationPath = Self.initialNavigationPath(document: document, activeCellID: self.activeCellID)
    }

    public func runDRC() {
        let service = LayoutDRCService()
        violations = service.run(document: editor.document, tech: tech).violations
    }

    // MARK: - Cell Navigation

    public var activeCell: LayoutCell? {
        guard let activeCellID else { return nil }
        return editor.document.cell(withID: activeCellID)
    }

    public var breadcrumbCells: [LayoutCell] {
        let doc = editor.document
        return cellNavigationPath.compactMap { doc.cell(withID: $0) }
    }

    public var allCells: [LayoutCell] {
        editor.document.cells.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var canNavigateBack: Bool {
        !cellBackStack.isEmpty
    }

    public var canOpenSelectedInstanceCell: Bool {
        selectedInstanceTargetCellID() != nil
    }

    public func openCell(_ cellID: UUID) {
        navigate(to: cellID, path: bestPath(to: cellID), recordBack: true)
    }

    public func openSelectedInstanceCell() {
        guard let selectedTargetCellID = selectedInstanceTargetCellID() else { return }
        let nextPath: [UUID]
        if cellNavigationPath.last == activeCellID {
            nextPath = cellNavigationPath + [selectedTargetCellID]
        } else {
            nextPath = bestPath(to: selectedTargetCellID)
        }
        navigate(to: selectedTargetCellID, path: nextPath, recordBack: true)
    }

    public func navigateToBreadcrumb(index: Int) {
        guard index >= 0, index < cellNavigationPath.count else { return }
        let nextPath = Array(cellNavigationPath.prefix(index + 1))
        guard let targetCellID = nextPath.last else { return }
        navigate(to: targetCellID, path: nextPath, recordBack: true)
    }

    public func navigateBack() {
        guard let previous = cellBackStack.popLast() else { return }
        restoreNavigationState(previous)
    }

    // MARK: - Shape Creation

    public func addRectangle(from start: LayoutPoint, to end: LayoutPoint) {
        guard let cellID = activeCellID else { return }
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let rect = LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
        let shape = LayoutShape(layer: activeLayer, geometry: .rect(rect))
        do {
            try editor.addShape(shape, to: cellID)
        } catch {
            handleError(error)
        }
    }

    public func addPolygon(points: [LayoutPoint]) {
        guard let cellID = activeCellID else { return }
        let polygon = LayoutPolygon(points: points)
        guard polygon.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .polygon(polygon))
        do {
            try editor.addShape(shape, to: cellID)
        } catch {
            handleError(error)
        }
    }

    public func addPath(points: [LayoutPoint]) {
        guard let cellID = activeCellID else { return }
        let path = LayoutPath(points: points, width: pathWidth, endCap: pathEndCap)
        guard path.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .path(path))
        do {
            try editor.addShape(shape, to: cellID)
        } catch {
            handleError(error)
        }
    }

    public func addVia(at point: LayoutPoint) {
        guard let cellID = activeCellID else { return }
        let via = LayoutVia(viaDefinitionID: activeViaID, position: point)
        do {
            try editor.addVia(via, to: cellID)
        } catch {
            handleError(error)
        }
    }

    public func addLabel(text: String, at point: LayoutPoint) {
        guard let cellID = activeCellID else { return }
        let label = LayoutLabel(text: text, position: point, layer: activeLayer)
        do {
            try editor.addLabel(label, to: cellID)
        } catch {
            handleError(error)
        }
    }

    public func addPin(name: String, at point: LayoutPoint, size: LayoutSize) {
        guard let cellID = activeCellID else { return }
        let pin = LayoutPin(name: name, position: point, size: size, layer: activeLayer)
        do {
            try editor.addPin(pin, to: cellID)
        } catch {
            handleError(error)
        }
    }

    // MARK: - Rulers

    public func addRuler(from start: LayoutPoint, to end: LayoutPoint) {
        rulers.append(LayoutRuler(start: start, end: end))
    }

    public func clearAllRulers() {
        rulers.removeAll()
    }

    // MARK: - Selection

    public func selectShape(at point: LayoutPoint) {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        for shape in cell.shapes.reversed() {
            guard isLayerVisible(shape.layer) else { continue }
            if LayoutGeometryAnalysis.contains(point, in: shape.geometry) {
                selectedShapeIDs = [shape.id]
                selectedInstanceID = nil
                return
            }
        }
        if let instID = selectInstance(at: point) {
            selectedInstanceID = instID
            selectedShapeIDs.removeAll()
            return
        }
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
    }

    public func selectInstance(at point: LayoutPoint) -> UUID? {
        for (inst, bounds) in instanceBoundingBoxes() {
            if bounds.contains(point) {
                return inst.id
            }
        }
        return nil
    }

    public func instanceBoundingBoxes() -> [(instance: LayoutInstance, bounds: LayoutRect)] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return [] }
        return cell.instances.compactMap { inst in
            guard let refCell = editor.document.cell(withID: inst.cellID) else { return nil }
            let localBounds = Self.cellBoundingBox(refCell)
            guard localBounds.size.width > 0, localBounds.size.height > 0 else { return nil }
            let transformedBounds = Self.transformRect(localBounds, by: inst.transform)
            return (inst, transformedBounds)
        }
    }

    public func documentShapes() -> [LayoutShape] {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return cell.shapes
    }

    /// Returns all shapes from the active cell hierarchy, recursively flattening
    /// instance references with their transforms applied.
    public func flattenedDocumentShapes() -> [LayoutShape] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return flattenShapes(cell: cell, transforms: [], depth: 0)
    }

    private func flattenShapes(
        cell: LayoutCell,
        transforms: [LayoutTransform],
        depth: Int
    ) -> [LayoutShape] {
        guard depth < 10 else { return [] }
        var result: [LayoutShape] = []

        for shape in cell.shapes {
            if transforms.isEmpty {
                result.append(shape)
            } else {
                var geo = shape.geometry
                for t in transforms {
                    geo = geo.transformed(by: t)
                }
                result.append(LayoutShape(layer: shape.layer, geometry: geo))
            }
        }

        for inst in cell.instances {
            guard let refCell = editor.document.cell(withID: inst.cellID) else { continue }
            result.append(contentsOf: flattenShapes(
                cell: refCell,
                transforms: [inst.transform] + transforms,
                depth: depth + 1
            ))
        }

        return result
    }

    // MARK: - Move Selected Shapes

    public func moveSelectedShapes(by delta: LayoutPoint) {
        guard let cellID = activeCellID else { return }
        guard !selectedShapeIDs.isEmpty else { return }

        for shapeID in selectedShapeIDs {
            guard let cell = editor.document.cell(withID: cellID),
                  let shape = cell.shapes.first(where: { $0.id == shapeID }) else { continue }

            let movedGeometry: LayoutGeometry
            switch shape.geometry {
            case .rect(let rect):
                movedGeometry = .rect(LayoutRect(
                    origin: LayoutPoint(x: rect.origin.x + delta.x, y: rect.origin.y + delta.y),
                    size: rect.size
                ))
            case .polygon(let poly):
                let movedPoints = poly.points.map {
                    LayoutPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                }
                movedGeometry = .polygon(LayoutPolygon(points: movedPoints))
            case .path(let path):
                let movedPoints = path.points.map {
                    LayoutPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                }
                movedGeometry = .path(LayoutPath(points: movedPoints, width: path.width, endCap: path.endCap))
            }

            do {
                try editor.removeShape(id: shapeID, from: cellID)
                var newShape = LayoutShape(layer: shape.layer, geometry: movedGeometry)
                newShape.netID = shape.netID
                newShape.properties = shape.properties
                try editor.addShape(newShape, to: cellID)
                // Update selection to the new shape ID
                selectedShapeIDs.remove(shapeID)
                selectedShapeIDs.insert(newShape.id)
            } catch {
                handleError(error)
            }
        }
    }

    // MARK: - Merge

    /// Merges all selected shapes on the same layer into polygons by computing their union.
    public func mergeSelectedShapes() {
        guard let cellID = activeCellID, !selectedShapeIDs.isEmpty else { return }
        guard let cell = editor.document.cell(withID: cellID) else { return }

        // Group selected shapes by layer
        var shapesByLayer: [LayoutLayerID: [LayoutShape]] = [:]
        for shape in cell.shapes where selectedShapeIDs.contains(shape.id) {
            shapesByLayer[shape.layer, default: []].append(shape)
        }

        for (layer, shapes) in shapesByLayer {
            guard shapes.count >= 2 else { continue }

            // Collect all polygons
            var polygons: [LayoutPolygon] = []
            for shape in shapes {
                switch shape.geometry {
                case .rect(let rect):
                    polygons.append(rect.toPolygon())
                case .polygon(let poly):
                    polygons.append(poly)
                case .path:
                    continue
                }
            }

            guard polygons.count >= 2 else { continue }

            let mergedPolygons = union(polygons: polygons, dbuPerMicron: editor.document.units.dbuPerMicron)
            guard !mergedPolygons.isEmpty else { continue }
            let mergedNetID = commonNetID(in: shapes)
            let mergedProperties = commonProperties(in: shapes)

            do {
                for shape in shapes {
                    if case .path = shape.geometry { continue }
                    try editor.removeShape(id: shape.id, from: cellID)
                }
                for polygon in mergedPolygons {
                    let merged = LayoutShape(
                        layer: layer,
                        netID: mergedNetID,
                        geometry: .polygon(polygon),
                        properties: mergedProperties
                    )
                    try editor.addShape(merged, to: cellID)
                }
            } catch {
                handleError(error)
            }
        }

        selectedShapeIDs.removeAll()
    }

    // MARK: - Bounding Box

    public func contentBounds() -> LayoutRect? {
        let shapes = flattenedDocumentShapes()
        guard let first = shapes.first else { return nil }
        var result = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in shapes.dropFirst() {
            result = result.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        return result
    }

    public func fitAll() {
        guard canvasSize.width > 0, canvasSize.height > 0,
              let bounds = contentBounds(),
              bounds.size.width > 0, bounds.size.height > 0 else {
            zoom = 1.0
            offset = .zero
            return
        }

        let margin: CGFloat = 40
        let availableWidth = canvasSize.width - margin * 2
        let availableHeight = canvasSize.height - margin * 2
        let scaleX = availableWidth / CGFloat(bounds.size.width)
        let scaleY = availableHeight / CGFloat(bounds.size.height)
        let newZoom = max(0.01, min(100000, min(scaleX, scaleY)))

        let centerX = CGFloat(bounds.origin.x) + CGFloat(bounds.size.width) / 2
        let centerY = CGFloat(bounds.origin.y) + CGFloat(bounds.size.height) / 2
        zoom = newZoom
        offset = CGPoint(
            x: canvasSize.width / 2 - centerX * newZoom,
            y: canvasSize.height / 2 - centerY * newZoom
        )
    }

    public func deleteSelectedShapes() {
        guard let cellID = activeCellID, !selectedShapeIDs.isEmpty else { return }
        for shapeID in selectedShapeIDs {
            do {
                try editor.removeShape(id: shapeID, from: cellID)
            } catch {
                handleError(error)
            }
        }
        selectedShapeIDs.removeAll()
    }

    // MARK: - File Import

    public func loadMaskData(from url: URL) throws {
        let resolvedTech: LayoutTechDatabase
        let sidecarResolver = LayoutTechSidecarResolver()
        if let sidecarTech = try sidecarResolver.resolve(for: url) {
            resolvedTech = sidecarTech
        } else {
            resolvedTech = tech
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw error
        }
        let converter = MaskDataFormatConverter(tech: resolvedTech)
        let document = try converter.importFromData(data)

        self.tech = resolvedTech
        self.gridSize = resolvedTech.grid
        self.activeLayer = resolvedTech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = resolvedTech.vias.first?.id ?? "VIA1"
        self.pathWidth = defaultPathWidth(for: resolvedTech)
        self.editor = LayoutDocumentEditor(document: document)
        self.activeCellID = document.topCellID ?? document.cells.first?.id
        self.cellNavigationPath = Self.initialNavigationPath(document: document, activeCellID: self.activeCellID)
        self.cellBackStack.removeAll()
        self.selectedShapeIDs.removeAll()
        self.selectedInstanceID = nil
        self.hiddenLayers.removeAll()
        self.violations.removeAll()
    }

    public func centerOn(_ point: LayoutPoint) {
        offset = CGPoint(
            x: canvasSize.width / 2 - CGFloat(point.x) * zoom,
            y: canvasSize.height / 2 - CGFloat(point.y) * zoom
        )
    }

    public func clearSelection() {
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
    }

    // MARK: - Layer Visibility

    public func isLayerVisible(_ layer: LayoutLayerID) -> Bool {
        !hiddenLayers.contains(layer)
    }

    public func toggleLayerVisibility(_ layer: LayoutLayerID) {
        if hiddenLayers.contains(layer) {
            hiddenLayers.remove(layer)
        } else {
            hiddenLayers.insert(layer)
        }
    }

    // MARK: - Angle-Constrained Snap

    /// Applies grid snap and then angle constraint relative to an anchor point.
    public func constrainedSnap(_ point: LayoutPoint, from anchor: LayoutPoint?) -> LayoutPoint {
        let gridSnapped = snapToGrid(point)
        guard let anchor else { return gridSnapped }
        return angleConstraint.snap(gridSnapped, from: anchor)
    }

    // MARK: - Zoom Steps

    public static let zoomSteps: [CGFloat] = [
        0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50,
        100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000
    ]

    public func zoomToStep(_ step: CGFloat) {
        let clamped = max(0.01, min(100000, step))
        let oldZoom = zoom
        guard oldZoom > 0 else { zoom = clamped; return }
        let scale = clamped / oldZoom
        offset = CGPoint(
            x: canvasSize.width / 2 - (canvasSize.width / 2 - offset.x) * scale,
            y: canvasSize.height / 2 - (canvasSize.height / 2 - offset.y) * scale
        )
        zoom = clamped
    }

    public func zoomInStep() {
        if let next = Self.zoomSteps.first(where: { $0 > zoom * 1.01 }) {
            zoomToStep(next)
        }
    }

    public func zoomOutStep() {
        if let prev = Self.zoomSteps.last(where: { $0 < zoom * 0.99 }) {
            zoomToStep(prev)
        }
    }

    // MARK: - Boolean Operations

    public func subtractFromShapes(cutRect: LayoutRect) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return }

        var operations: [(removeID: UUID, addPolygons: [LayoutPolygon], layer: LayoutLayerID)] = []

        for shape in cell.shapes {
            guard shape.layer == activeLayer else { continue }

            let polygon: LayoutPolygon
            switch shape.geometry {
            case .rect(let rect):
                guard rect.intersects(cutRect) else { continue }
                polygon = rect.toPolygon()
            case .polygon(let poly):
                let bbox = LayoutGeometryAnalysis.boundingBox(for: poly)
                guard bbox.intersects(cutRect) else { continue }
                polygon = poly
            case .path:
                continue
            }

            let remainders = polygon.subtract(cut: cutRect)
            if remainders.count != 1 || remainders.first != polygon {
                operations.append((shape.id, remainders, shape.layer))
            }
        }

        guard !operations.isEmpty else { return }

        for op in operations {
            do {
                try editor.removeShape(id: op.removeID, from: cellID)
                for poly in op.addPolygons {
                    let newShape = LayoutShape(layer: op.layer, geometry: .polygon(poly))
                    try editor.addShape(newShape, to: cellID)
                }
            } catch {
                handleError(error)
            }
        }
        selectedShapeIDs.removeAll()
    }

    public func splitShapes(from start: LayoutPoint, to end: LayoutPoint) {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else { return }

        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let isHorizontalCut = dx >= dy
        let cutPos = isHorizontalCut
            ? (start.y + end.y) / 2
            : (start.x + end.x) / 2

        var operations: [(removeID: UUID, a: LayoutPolygon, b: LayoutPolygon, layer: LayoutLayerID)] = []

        for shape in cell.shapes {
            guard shape.layer == activeLayer else { continue }

            let polygon: LayoutPolygon
            switch shape.geometry {
            case .rect(let rect):
                polygon = rect.toPolygon()
            case .polygon(let poly):
                polygon = poly
            case .path:
                continue
            }

            if isHorizontalCut {
                if let (bottom, top) = polygon.splitHorizontally(at: cutPos) {
                    operations.append((shape.id, bottom, top, shape.layer))
                }
            } else {
                if let (left, right) = polygon.splitVertically(at: cutPos) {
                    operations.append((shape.id, left, right, shape.layer))
                }
            }
        }

        guard !operations.isEmpty else { return }

        for op in operations {
            do {
                try editor.removeShape(id: op.removeID, from: cellID)
                try editor.addShape(LayoutShape(layer: op.layer, geometry: .polygon(op.a)), to: cellID)
                try editor.addShape(LayoutShape(layer: op.layer, geometry: .polygon(op.b)), to: cellID)
            } catch {
                handleError(error)
            }
        }
        selectedShapeIDs.removeAll()
    }

    // MARK: - Grid Snap

    public func snapToGrid(_ point: LayoutPoint) -> LayoutPoint {
        let g = gridSize
        guard g > 0 else { return point }
        return LayoutPoint(
            x: (point.x / g).rounded() * g,
            y: (point.y / g).rounded() * g
        )
    }

    // MARK: - Private Helpers

    private func selectedInstanceTargetCellID() -> UUID? {
        guard let selectedInstanceID,
              let activeCellID,
              let cell = editor.document.cell(withID: activeCellID),
              let instance = cell.instances.first(where: { $0.id == selectedInstanceID }) else {
            return nil
        }
        return instance.cellID
    }

    private func navigate(to cellID: UUID, path: [UUID], recordBack: Bool) {
        guard editor.document.cell(withID: cellID) != nil else { return }

        if recordBack {
            let current = CellNavigationState(activeCellID: activeCellID, path: cellNavigationPath)
            let isMeaningfulTransition = current.activeCellID != cellID || current.path != path
            if isMeaningfulTransition {
                cellBackStack.append(current)
                if cellBackStack.count > 100 {
                    cellBackStack.removeFirst(cellBackStack.count - 100)
                }
            }
        }

        activeCellID = cellID
        cellNavigationPath = path
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
        highlightedInstanceIDs.removeAll()
        violations.removeAll()
    }

    private func restoreNavigationState(_ state: CellNavigationState) {
        guard let restoredID = state.activeCellID,
              editor.document.cell(withID: restoredID) != nil else { return }

        let normalizedPath = state.path.filter { editor.document.cell(withID: $0) != nil }
        activeCellID = restoredID
        cellNavigationPath = normalizedPath.isEmpty ? bestPath(to: restoredID) : normalizedPath
        selectedShapeIDs.removeAll()
        selectedInstanceID = nil
        highlightedInstanceIDs.removeAll()
        violations.removeAll()
    }

    private static func initialNavigationPath(document: LayoutDocument, activeCellID: UUID?) -> [UUID] {
        guard let activeCellID else { return [] }
        if let topCellID = document.topCellID {
            if topCellID == activeCellID {
                return [topCellID]
            }
            return [topCellID, activeCellID]
        }
        return [activeCellID]
    }

    private func bestPath(to cellID: UUID) -> [UUID] {
        let document = editor.document
        guard let topCellID = document.topCellID else { return [cellID] }
        if cellID == topCellID { return [topCellID] }

        var parentByChild: [UUID: UUID] = [:]
        var queue: [UUID] = [topCellID]
        var cursor = 0
        var visited: Set<UUID> = [topCellID]

        while cursor < queue.count {
            let parentID = queue[cursor]
            cursor += 1

            guard let parentCell = document.cell(withID: parentID) else { continue }
            for instance in parentCell.instances {
                let childID = instance.cellID
                if parentByChild[childID] == nil {
                    parentByChild[childID] = parentID
                }
                if !visited.contains(childID) {
                    visited.insert(childID)
                    queue.append(childID)
                }
            }
        }

        var chain: [UUID] = [cellID]
        var current = cellID
        while let parent = parentByChild[current] {
            chain.append(parent)
            if parent == topCellID {
                break
            }
            current = parent
        }

        if chain.last == topCellID {
            return chain.reversed()
        }

        return [topCellID, cellID]
    }

    private static func cellBoundingBox(_ cell: LayoutCell) -> LayoutRect {
        guard let first = cell.shapes.first else { return .zero }
        var bbox = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in cell.shapes.dropFirst() {
            bbox = bbox.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        return bbox
    }

    private static func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let corners = [
            transform.apply(to: rect.origin),
            transform.apply(to: LayoutPoint(x: rect.maxX, y: rect.origin.y)),
            transform.apply(to: LayoutPoint(x: rect.origin.x, y: rect.maxY)),
            transform.apply(to: LayoutPoint(x: rect.maxX, y: rect.maxY)),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func defaultPathWidth(for tech: LayoutTechDatabase) -> Double {
        // Use the minimum width of the first layer, or fall back to grid
        if let firstLayer = tech.layers.first,
           let ruleSet = tech.ruleSet(for: firstLayer.id),
           ruleSet.minWidth > 0 {
            return ruleSet.minWidth
        }
        return tech.grid * 10
    }

    private func handleError(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func union(polygons: [LayoutPolygon], dbuPerMicron: Double) -> [LayoutPolygon] {
        let boundaries = polygons.compactMap { irBoundary(from: $0, dbuPerMicron: dbuPerMicron) }
        guard let first = boundaries.first else { return [] }

        var region = Region(polygons: [first])
        for boundary in boundaries.dropFirst() {
            region = region.or(Region(polygons: [boundary]))
        }

        return region.polygons.compactMap { polygon(from: $0, dbuPerMicron: dbuPerMicron) }
    }

    private func irBoundary(from polygon: LayoutPolygon, dbuPerMicron: Double) -> IRBoundary? {
        guard polygon.points.count >= 3, dbuPerMicron > 0 else { return nil }
        var points = polygon.points.map { point in
            IRPoint(
                x: Int32((point.x * dbuPerMicron).rounded()),
                y: Int32((point.y * dbuPerMicron).rounded())
            )
        }
        guard Set(points).count >= 3 else { return nil }
        if points.first != points.last {
            points.append(points[0])
        }
        return IRBoundary(layer: 0, datatype: 0, points: points)
    }

    private func polygon(from boundary: IRBoundary, dbuPerMicron: Double) -> LayoutPolygon? {
        guard dbuPerMicron > 0 else { return nil }
        var points = boundary.points.map { point in
            LayoutPoint(
                x: Double(point.x) / dbuPerMicron,
                y: Double(point.y) / dbuPerMicron
            )
        }
        if points.first == points.last {
            points.removeLast()
        }
        guard points.count >= 3 else { return nil }
        return LayoutPolygon(points: points)
    }

    private func commonNetID(in shapes: [LayoutShape]) -> UUID? {
        guard let first = shapes.first else { return nil }
        return shapes.allSatisfy { $0.netID == first.netID } ? first.netID : nil
    }

    private func commonProperties(in shapes: [LayoutShape]) -> [String: String] {
        guard let first = shapes.first else { return [:] }
        return shapes.allSatisfy { $0.properties == first.properties } ? first.properties : [:]
    }
}
