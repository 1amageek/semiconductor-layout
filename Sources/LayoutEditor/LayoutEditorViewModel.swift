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

    // MARK: - Live DRC (DRD)

    /// Design-rule-driven editing mode. In `observe` and `enforce` every
    /// edit re-verifies incrementally and ``violations`` stays live; in
    /// `enforce` interactive drags additionally stick at legal positions.
    public var drdMode: DRDMode = .observe {
        didSet {
            guard drdMode != oldValue else { return }
            if drdMode == .off {
                liveDRC = nil
                staleViolationKinds = []
            } else {
                resyncLiveDRC()
            }
        }
    }

    /// Violation kinds in ``violations`` not re-verified since the last
    /// edit (the live session's deferred tier, or everything when live
    /// verification is unavailable).
    public private(set) var staleViolationKinds: Set<LayoutViolationKind> = []

    /// How the last design-rule-driven drag proposal resolved, for canvas
    /// feedback while a drag is active.
    public private(set) var dragOutcome: DRDDragOutcome?

    private var liveDRC: IncrementalDRCSession?
    private var dragSession: DRDDragSession?
    private var dragOriginShapes: [LayoutShape]?

    // MARK: - Live Connectivity

    /// Exact connectivity of the active cell, maintained incrementally
    /// across every edit. `nil` means live connectivity is unavailable
    /// (disabled, or the session failed and could not be rebuilt) — the
    /// editor never shows a stale analysis as if it were current.
    public private(set) var connectivityAnalysis: ConnectivityAnalysis?

    /// Live connectivity extraction; independent of ``drdMode`` because
    /// nets/shorts/opens are a different verdict channel than design
    /// rules.
    public var liveConnectivityEnabled: Bool = true {
        didSet {
            guard liveConnectivityEnabled != oldValue else { return }
            if liveConnectivityEnabled {
                resyncLiveConnectivity()
            } else {
                liveConnectivity = nil
                connectivityAnalysis = nil
            }
        }
    }

    /// Flylines of every open net — the unrouted-connection guides the
    /// canvas draws live while editing.
    public var flylines: [Flyline] { connectivityAnalysis?.flylines ?? [] }

    /// The extracted net the highlight anchor currently belongs to,
    /// re-resolved against the live analysis so the highlight follows the
    /// conductor through edits.
    public var highlightedNet: ConnectivityNet? {
        guard let anchor = netHighlightAnchor, let analysis = connectivityAnalysis else { return nil }
        switch anchor {
        case .shape(let id): return analysis.nets.first { $0.shapeIDs.contains(id) }
        case .via(let id): return analysis.nets.first { $0.viaIDs.contains(id) }
        }
    }

    private enum NetHighlightAnchor {
        case shape(UUID)
        case via(UUID)
    }

    private var liveConnectivity: LiveConnectivitySession?
    private var netHighlightAnchor: NetHighlightAnchor?

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
        resyncLiveDRC()
        resyncLiveConnectivity()
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
        resyncLiveDRC()
        resyncLiveConnectivity()
    }

    /// Full verification on demand: re-verifies the live session's
    /// deferred tier when one is active, or runs the batch checker.
    public func runDRC() {
        if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            let service = LayoutDRCService()
            violations = service.run(document: editor.document, tech: tech, cellID: activeCellID).violations
            staleViolationKinds = []
        }
    }

    // MARK: - Live DRC Plumbing

    /// (Re)builds the live session from the current document and active
    /// cell. On failure the error is surfaced and every violation kind is
    /// declared stale rather than pretending the snapshot is current.
    private func resyncLiveDRC() {
        guard drdMode != .off, let cellID = activeCellID else {
            liveDRC = nil
            return
        }
        do {
            let result: LayoutDRCResult
            if let liveDRC {
                result = try liveDRC.rebuild(document: editor.document, cellID: cellID)
            } else {
                let session = try IncrementalDRCSession(
                    document: editor.document,
                    tech: tech,
                    cellID: cellID
                )
                liveDRC = session
                result = session.currentResult
            }
            violations = result.violations
            staleViolationKinds = []
        } catch {
            liveDRC = nil
            staleViolationKinds = Set(LayoutViolationKind.allCases)
            handleError(error)
        }
    }

    /// Tears down and rebuilds the live session — required when the
    /// technology database changes, which a session cannot absorb.
    private func restartLiveDRC() {
        liveDRC = nil
        resyncLiveDRC()
    }

    // MARK: - Live Connectivity Plumbing

    /// (Re)builds the connectivity session from the current document and
    /// active cell. On failure the error is surfaced and the analysis
    /// becomes `nil` — unavailable, never silently stale.
    private func resyncLiveConnectivity() {
        guard liveConnectivityEnabled, let cellID = activeCellID else {
            liveConnectivity = nil
            connectivityAnalysis = nil
            return
        }
        do {
            if let liveConnectivity {
                connectivityAnalysis = try liveConnectivity.rebuild(
                    document: editor.document,
                    cellID: cellID
                )
            } else {
                let session = try LiveConnectivitySession(
                    document: editor.document,
                    tech: tech,
                    cellID: cellID
                )
                liveConnectivity = session
                connectivityAnalysis = session.currentAnalysis
            }
        } catch {
            liveConnectivity = nil
            connectivityAnalysis = nil
            handleError(error)
        }
    }

    /// Tears down and rebuilds the connectivity session — required when
    /// the technology database changes, which a session cannot absorb.
    private func restartLiveConnectivity() {
        liveConnectivity = nil
        resyncLiveConnectivity()
    }

    /// Applies a document delta to the connectivity session in lockstep.
    /// A rejected delta is a programming error in delta construction:
    /// surface it and rebuild so the analysis stays truthful.
    private func applyConnectivityDelta(_ delta: LayoutEditDelta) {
        guard let liveConnectivity else { return }
        do {
            connectivityAnalysis = try liveConnectivity.apply(delta).analysis
        } catch {
            handleError(error)
            resyncLiveConnectivity()
        }
    }

    /// Anchors the net highlight to a shape; the highlighted net follows
    /// the conductor that shape belongs to as the layout changes.
    public func highlightNet(ofShape id: UUID) {
        netHighlightAnchor = .shape(id)
    }

    /// Anchors the net highlight to a via.
    public func highlightNet(ofVia id: UUID) {
        netHighlightAnchor = .via(id)
    }

    public func clearNetHighlight() {
        netHighlightAnchor = nil
    }

    /// Single choke point for geometry edits: applies the delta to the
    /// document and the live session with identical ordering semantics,
    /// keeping ``violations`` exact. Discrete edits re-verify the deferred
    /// antenna tier immediately; transient (gesture) edits defer it and
    /// report it via ``staleViolationKinds``.
    private func commitDelta(_ delta: LayoutEditDelta, transient: Bool = false) {
        guard let cellID = activeCellID else { return }
        do {
            if transient {
                try editor.performTransient { doc in
                    try Self.applyDelta(delta, to: &doc, cellID: cellID)
                }
            } else {
                try editor.perform { doc in
                    try Self.applyDelta(delta, to: &doc, cellID: cellID)
                }
            }
        } catch {
            handleError(error)
            return
        }

        if let liveDRC {
            do {
                let update = try liveDRC.apply(delta)
                if transient {
                    violations = update.result.violations
                    staleViolationKinds = update.staleKinds
                } else {
                    violations = liveDRC.commit().violations
                    staleViolationKinds = []
                }
            } catch {
                // The document mutation succeeded but the session rejected
                // the delta — a programming error in delta construction.
                // Surface it and rebuild the session from the document so
                // the live snapshot stays truthful.
                handleError(error)
                resyncLiveDRC()
            }
        }
        applyConnectivityDelta(delta)
    }

    /// Applies a delta to the cell with the session's ordering semantics:
    /// updated elements keep their position, removed elements drop out,
    /// added elements append in delta order.
    private static func applyDelta(
        _ delta: LayoutEditDelta,
        to doc: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard var cell = doc.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
        }
        for id in delta.removedShapeIDs {
            guard let index = cell.shapes.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.shapeNotFound(id)
            }
            cell.shapes.remove(at: index)
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        for via in delta.updatedVias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else {
                throw LayoutCoreError.viaNotFound(via.id)
            }
            cell.vias[index] = via
        }
        for id in delta.removedViaIDs {
            guard let index = cell.vias.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.viaNotFound(id)
            }
            cell.vias.remove(at: index)
        }
        cell.vias.append(contentsOf: delta.addedVias)
        doc.updateCell(cell)
    }

    // MARK: - Undo / Redo

    public var canUndo: Bool { editor.canUndo }
    public var canRedo: Bool { editor.canRedo }

    public func undo() {
        editor.undo()
        resyncLiveDRC()
        resyncLiveConnectivity()
    }

    public func redo() {
        editor.redo()
        resyncLiveDRC()
        resyncLiveConnectivity()
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
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let rect = LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
        let shape = LayoutShape(layer: activeLayer, geometry: .rect(rect))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addPolygon(points: [LayoutPoint]) {
        let polygon = LayoutPolygon(points: points)
        guard polygon.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .polygon(polygon))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addPath(points: [LayoutPoint]) {
        let path = LayoutPath(points: points, width: pathWidth, endCap: pathEndCap)
        guard path.isValid else { return }
        let shape = LayoutShape(layer: activeLayer, geometry: .path(path))
        commitDelta(LayoutEditDelta(addedShapes: [shape]))
    }

    public func addVia(at point: LayoutPoint) {
        let via = LayoutVia(viaDefinitionID: activeViaID, position: point)
        commitDelta(LayoutEditDelta(addedVias: [via]))
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
            return
        }
        // Pins participate in connectivity checks but are structural for
        // the live sessions, so they require a rebuild rather than a delta.
        resyncLiveDRC()
        resyncLiveConnectivity()
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

    public func documentVias() -> [LayoutVia] {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return cell.vias
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

    /// Moves the selection by a vector as one discrete, ID-preserving
    /// edit — the path for keyboard nudges and programmatic moves.
    /// Interactive drags go through ``beginShapeDrag()`` /
    /// ``updateShapeDrag(to:)`` / ``endShapeDrag()`` instead.
    public func moveSelectedShapes(by delta: LayoutPoint) {
        let moved = selectedShapes().map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: delta)
            return copy
        }
        guard !moved.isEmpty else { return }
        commitDelta(LayoutEditDelta(updatedShapes: moved))
    }

    private func selectedShapes() -> [LayoutShape] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID),
              !selectedShapeIDs.isEmpty else { return [] }
        return cell.shapes.filter { selectedShapeIDs.contains($0.id) }
    }

    // MARK: - Interactive Drag (DRD)

    /// Whether an interactive shape drag is in progress.
    public var isDraggingShapes: Bool { dragOriginShapes != nil }

    /// Starts an interactive drag of the selected shapes. The whole drag
    /// collapses into one undo step; in `observe`/`enforce` mode every
    /// tick re-verifies through the live session.
    public func beginShapeDrag() {
        guard dragOriginShapes == nil else { return }
        let shapes = selectedShapes()
        guard !shapes.isEmpty else { return }
        editor.recordUndoBoundary()
        dragOriginShapes = shapes
        if let liveDRC {
            dragSession = DRDDragSession(session: liveDRC, shapes: shapes, grid: gridSize)
        }
    }

    /// Moves the drag to a cumulative offset from the drag origin. In
    /// enforce mode the offset may resolve to the closest legal position;
    /// the resolution is reported via ``dragOutcome``.
    public func updateShapeDrag(to offset: LayoutPoint) {
        guard let origin = dragOriginShapes else { return }
        let applied: LayoutPoint
        if let dragSession {
            do {
                let resolution = try dragSession.propose(
                    offset: offset,
                    enforce: drdMode == .enforce
                )
                violations = resolution.result.violations
                staleViolationKinds = liveDRC?.staleKinds ?? []
                dragOutcome = resolution.outcome
                applied = resolution.appliedOffset
            } catch {
                handleError(error)
                resyncLiveDRC()
                return
            }
        } else {
            applied = snapToGrid(offset)
        }
        mirrorDragOffset(applied, origin: origin)
    }

    /// Ends the drag at its current position and re-verifies the deferred
    /// tier so the snapshot is exact again.
    public func endShapeDrag() {
        guard dragOriginShapes != nil else { return }
        dragOriginShapes = nil
        dragSession = nil
        dragOutcome = nil
        if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    /// Aborts the drag and restores the dragged shapes to their origin.
    public func cancelShapeDrag() {
        guard let origin = dragOriginShapes else { return }
        if let dragSession {
            do {
                violations = try dragSession.cancel().violations
                staleViolationKinds = liveDRC?.staleKinds ?? []
            } catch {
                handleError(error)
                resyncLiveDRC()
            }
        }
        mirrorDragOffset(.zero, origin: origin)
        dragOriginShapes = nil
        dragSession = nil
        dragOutcome = nil
        if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        }
    }

    /// Mirrors the drag position into the document as a transient edit so
    /// the canvas renders from the same state the live session verified.
    private func mirrorDragOffset(_ offset: LayoutPoint, origin: [LayoutShape]) {
        guard let cellID = activeCellID else { return }
        let moved = origin.map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: offset)
            return copy
        }
        do {
            try editor.performTransient { doc in
                try Self.applyDelta(LayoutEditDelta(updatedShapes: moved), to: &doc, cellID: cellID)
            }
        } catch {
            handleError(error)
            return
        }
        // The DRC side of the drag verifies through DRDDragSession; the
        // connectivity session follows the document directly so flylines
        // and short/open verdicts stay live during the gesture.
        applyConnectivityDelta(LayoutEditDelta(updatedShapes: moved))
    }

    // MARK: - Merge

    /// Merges all selected shapes on the same layer into polygons by
    /// computing their union. All layers merge as one edit: one undo step,
    /// one live verification.
    public func mergeSelectedShapes() {
        guard let cellID = activeCellID, !selectedShapeIDs.isEmpty else { return }
        guard let cell = editor.document.cell(withID: cellID) else { return }

        // Group selected shapes by layer
        var shapesByLayer: [LayoutLayerID: [LayoutShape]] = [:]
        for shape in cell.shapes where selectedShapeIDs.contains(shape.id) {
            shapesByLayer[shape.layer, default: []].append(shape)
        }

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

        for (layer, shapes) in shapesByLayer {
            guard shapes.count >= 2 else { continue }

            // Collect the mergeable shapes (paths keep their centerline
            // semantics and stay out of boolean merges).
            var polygons: [LayoutPolygon] = []
            var mergeable: [LayoutShape] = []
            for shape in shapes {
                switch shape.geometry {
                case .rect(let rect):
                    polygons.append(rect.toPolygon())
                    mergeable.append(shape)
                case .polygon(let poly):
                    polygons.append(poly)
                    mergeable.append(shape)
                case .path:
                    continue
                }
            }

            guard polygons.count >= 2 else { continue }

            let mergedPolygons = union(polygons: polygons, dbuPerMicron: editor.document.units.dbuPerMicron)
            guard !mergedPolygons.isEmpty else { continue }
            let mergedNetID = commonNetID(in: mergeable)
            let mergedProperties = commonProperties(in: mergeable)

            removedIDs.append(contentsOf: mergeable.map(\.id))
            for polygon in mergedPolygons {
                addedShapes.append(LayoutShape(
                    layer: layer,
                    netID: mergedNetID,
                    geometry: .polygon(polygon),
                    properties: mergedProperties
                ))
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
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
        let ids = selectedShapes().map(\.id)
        guard !ids.isEmpty else { return }
        commitDelta(LayoutEditDelta(removedShapeIDs: ids))
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
        // The technology may have changed with the document; a live
        // session cannot absorb that, so start fresh ones.
        restartLiveDRC()
        restartLiveConnectivity()
        clearNetHighlight()
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

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

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
                removedIDs.append(shape.id)
                for poly in remainders {
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(poly)))
                }
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
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

        var removedIDs: [UUID] = []
        var addedShapes: [LayoutShape] = []

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
                    removedIDs.append(shape.id)
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(bottom)))
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(top)))
                }
            } else {
                if let (left, right) = polygon.splitVertically(at: cutPos) {
                    removedIDs.append(shape.id)
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(left)))
                    addedShapes.append(LayoutShape(layer: shape.layer, geometry: .polygon(right)))
                }
            }
        }

        guard !removedIDs.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: addedShapes, removedShapeIDs: removedIDs))
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
        clearNetHighlight()
        resyncLiveDRC()
        resyncLiveConnectivity()
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
        clearNetHighlight()
        resyncLiveDRC()
        resyncLiveConnectivity()
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
