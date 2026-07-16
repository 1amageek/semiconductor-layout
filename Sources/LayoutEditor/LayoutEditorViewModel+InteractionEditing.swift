import Foundation
import LayoutCore
import LayoutVerify

extension LayoutEditorViewModel {
    // MARK: - Edit In Place

    public var isEditingInPlace: Bool { !inPlaceInstancePath.isEmpty }

    /// The cell that editing verbs and selection operate on: the in-place
    /// child when a context is entered, otherwise the active cell.
    public var editTargetCellID: UUID? {
        resolveInPlacePath()?.targetCellID ?? activeCellID
    }

    struct InPlaceResolution {
        var targetCellID: UUID
        /// Outermost-first transforms of the entered occurrence chain.
        var transforms: [LayoutTransform]
    }

    func resolveInPlacePath() -> InPlaceResolution? {
        guard !inPlaceInstancePath.isEmpty, var cellID = activeCellID else { return nil }
        var transforms: [LayoutTransform] = []
        for instanceID in inPlaceInstancePath {
            guard let cell = editor.document.cell(withID: cellID),
                  let instance = cell.instances.first(where: { $0.id == instanceID }) else {
                return nil
            }
            transforms.append(instance.transform)
            cellID = instance.cellID
        }
        return InPlaceResolution(targetCellID: cellID, transforms: transforms)
    }

    /// Descends the edit context into one instance of the current edit
    /// target. The viewed cell stays on screen; pointer input is mapped
    /// through the occurrence chain into the child's coordinate space.
    public func enterInPlaceEdit(instanceID: UUID) {
        guard let hostCellID = editTargetCellID,
              let host = editor.document.cell(withID: hostCellID),
              let instance = host.instances.first(where: { $0.id == instanceID }) else {
            handleError(LayoutCoreError.instanceNotFound(instanceID))
            return
        }
        guard instance.repetition == nil else {
            handleError(LayoutEditorError.arrayedInstanceEditInPlace(instanceID))
            return
        }
        guard instance.transform.magnification != 0 else {
            handleError(LayoutEditorError.degenerateInstanceTransform(instanceID))
            return
        }
        cancelRoute()
        inPlaceInstancePath.append(instanceID)
        clearSelection()
        rebuildActiveElementIndex()
    }

    /// Ascends one level of the in-place context.
    public func exitInPlaceEdit() {
        guard isEditingInPlace else { return }
        inPlaceInstancePath.removeLast()
        clearSelection()
        rebuildActiveElementIndex()
        if inPlaceVerificationPending {
            resyncAfterInPlaceEdit()
        }
    }

    /// View-space point → edit-target local space, through the inverse of
    /// the occurrence chain. Identity outside an in-place context.
    public func mapToEditSpace(_ point: LayoutPoint) -> LayoutPoint {
        guard let resolution = resolveInPlacePath() else { return point }
        var mapped = point
        for transform in resolution.transforms {
            do {
                mapped = try transform.inverseApply(to: mapped)
            } catch {
                handleError(error)
                return point
            }
        }
        return mapped
    }

    /// Edit-target local point → view space, for selection overlays.
    public func mapFromEditSpace(_ point: LayoutPoint) -> LayoutPoint {
        guard let resolution = resolveInPlacePath() else { return point }
        var mapped = point
        for transform in resolution.transforms.reversed() {
            mapped = transform.apply(to: mapped)
        }
        return mapped
    }

    /// View-space direction → edit-target direction (linear part only).
    public func mapVectorToEditSpace(_ vector: LayoutPoint) -> LayoutPoint {
        let origin = mapToEditSpace(.zero)
        let tip = mapToEditSpace(vector)
        return LayoutPoint(x: tip.x - origin.x, y: tip.y - origin.y)
    }

    /// Canvas input point in the space editing verbs operate in. Inside
    /// an in-place context the point is mapped first and snapped on the
    /// CHILD's grid — one composed transform per point, so there is no
    /// view-then-child double rounding.
    func editPoint(_ point: LayoutPoint) -> LayoutPoint {
        isEditingInPlace ? snapToGrid(mapToEditSpace(point)) : point
    }

    func editVector(_ vector: LayoutPoint) -> LayoutPoint {
        isEditingInPlace ? mapVectorToEditSpace(vector) : vector
    }

    /// Child-space deltas are not expressible to the top-context live
    /// sessions, so an in-place edit re-derives them from the document.
    /// The fan-out to every occurrence of the edited cell is exact: the
    /// sessions flatten the viewed cell, which contains them all.
    func resyncAfterInPlaceEdit() {
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
        inPlaceVerificationPending = false
    }

    // MARK: - Selection

    public func selectShape(at point: LayoutPoint) {
        guard let cellID = editTargetCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        let local = isEditingInPlace ? mapToEditSpace(point) : point
        for shape in cell.shapes.reversed() {
            guard isLayerVisible(shape.layer) else { continue }
            if LayoutGeometryAnalysis.contains(local, in: shape.geometry) {
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

    /// Selects shapes by marquee box. Window mode selects shapes whose
    /// bounding box lies entirely inside the box; crossing mode selects
    /// shapes whose bounding box intersects it. Hidden layers never
    /// participate. With `additive`, hits join the current selection
    /// instead of replacing it.
    public func selectShapes(in box: LayoutRect, mode: LayoutMarqueeMode, additive: Bool = false) {
        guard let cellID = editTargetCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        // Inside an in-place context the marquee corners are mapped into
        // the child space; under a rotated occurrence the box becomes the
        // bounding box of the mapped corners.
        let box = isEditingInPlace ? Self.boundingBox(
            of: [
                mapToEditSpace(LayoutPoint(x: box.minX, y: box.minY)),
                mapToEditSpace(LayoutPoint(x: box.maxX, y: box.minY)),
                mapToEditSpace(LayoutPoint(x: box.maxX, y: box.maxY)),
                mapToEditSpace(LayoutPoint(x: box.minX, y: box.maxY)),
            ]
        ) : box
        var hits: Set<UUID> = []
        for shape in cell.shapes {
            guard isLayerVisible(shape.layer) else { continue }
            let bounds = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            let matched: Bool
            switch mode {
            case .window:
                matched = box.minX <= bounds.minX && box.minY <= bounds.minY
                    && box.maxX >= bounds.maxX && box.maxY >= bounds.maxY
            case .crossing:
                matched = box.intersects(bounds)
            }
            if matched {
                hits.insert(shape.id)
            }
        }
        if additive {
            selectedShapeIDs.formUnion(hits)
        } else {
            selectedShapeIDs = hits
        }
        if !additive || !hits.isEmpty {
            selectedInstanceID = nil
        }
    }

    public func selectInstance(at point: LayoutPoint) -> UUID? {
        let local = isEditingInPlace ? mapToEditSpace(point) : point
        for (inst, bounds) in instanceBoundingBoxes(in: editTargetCellID) {
            if bounds.contains(local) {
                return inst.id
            }
        }
        return nil
    }

    public func instanceBoundingBoxes() -> [(instance: LayoutInstance, bounds: LayoutRect)] {
        instanceBoundingBoxes(in: activeCellID)
    }

    private func instanceBoundingBoxes(
        in cellID: UUID?
    ) -> [(instance: LayoutInstance, bounds: LayoutRect)] {
        guard let cellID,
              let cell = editor.document.cell(withID: cellID) else { return [] }
        return cell.instances.compactMap { inst in
            guard let refCell = editor.document.cell(withID: inst.cellID) else { return nil }
            let localBounds = Self.cellBoundingBox(refCell, in: editor.document)
            guard localBounds.size.width > 0, localBounds.size.height > 0 else { return nil }
            let transformedBounds = inst.occurrenceTransforms()
                .map { Self.transformRect(localBounds, by: $0) }
                .reduce(nil as LayoutRect?) { partial, box in
                    partial.map { $0.union(box) } ?? box
                }
            guard let transformedBounds else { return nil }
            return (inst, transformedBounds)
        }
    }

    /// The shapes editing and selection operate on. Inside an in-place
    /// context these are the EDIT TARGET cell's shapes with their geometry
    /// mapped into view space through the entered occurrence chain, so the
    /// canvas's selection drawing, handle hit-testing and drag pickup work
    /// unchanged; the IDs stay the child cell's real shape IDs.
    public func documentShapes() -> [LayoutShape] {
        if let resolution = resolveInPlacePath() {
            guard let cell = editor.document.cell(withID: resolution.targetCellID) else {
                return []
            }
            return cell.shapes.map { shape in
                var mapped = shape
                for transform in resolution.transforms.reversed() {
                    mapped.geometry = mapped.geometry.transformed(by: transform)
                }
                return mapped
            }
        }
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

    /// All pins of the active cell hierarchy at their flattened positions
    /// — the terminals a wiring or SDL flow targets.
    public func flattenedDocumentPins() -> [LayoutPin] {
        guard let cellID = activeCellID,
              let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        var content = FlattenedContent()
        Self.collectFlattenedContent(
            of: cell,
            in: editor.document,
            transforms: [],
            depth: 0,
            into: &content
        )
        return content.pins
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
            for occurrenceTransform in inst.occurrenceTransforms() {
                result.append(contentsOf: flattenShapes(
                    cell: refCell,
                    transforms: [occurrenceTransform] + transforms,
                    depth: depth + 1
                ))
            }
        }

        return result
    }

    // MARK: - Move Selected Shapes

    /// Moves the selection by a vector as one discrete, ID-preserving
    /// edit — the path for keyboard nudges and programmatic moves.
    /// Interactive drags go through ``beginShapeDrag()`` /
    /// ``updateShapeDrag(to:)`` / ``endShapeDrag()`` instead.
    public func moveSelectedShapes(by delta: LayoutPoint) {
        let delta = editVector(delta)
        let moved = selectedShapes().map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: delta)
            return copy
        }
        guard !moved.isEmpty else { return }
        commitDelta(LayoutEditDelta(updatedShapes: moved))
    }

    func selectedShapes() -> [LayoutShape] {
        guard !selectedShapeIDs.isEmpty else { return [] }
        // Resolved through the active-element index instead of scanning
        // the cell; canonical ID order keeps multi-select verbs
        // deterministic (sessions treat delta arrays as sets).
        return selectedShapeIDs
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { activeShapesByID[$0] }
    }

    // MARK: - Duplicate / Rotate / Mirror

    /// Duplicates the selection offset by one grid step on each axis —
    /// the default placement for the keyboard and menu duplicate commands.
    public func duplicateSelectedShapesByGridStep() {
        duplicateSelectedShapes(by: LayoutPoint(x: gridSize, y: gridSize))
    }

    /// Copies the selection, offset by a vector, as one discrete edit.
    /// The copies get fresh identities but keep their net assignment, so
    /// a copied labeled wire honestly reports as an open until it is
    /// wired up. Selection moves to the copies that landed.
    public func duplicateSelectedShapes(by offset: LayoutPoint) {
        let offset = editVector(offset)
        let copies = selectedShapes().map { shape in
            LayoutShape(
                layer: shape.layer,
                netID: shape.netID,
                geometry: shape.geometry.translated(by: offset),
                properties: shape.properties
            )
        }
        guard !copies.isEmpty else { return }
        commitDelta(LayoutEditDelta(addedShapes: copies))
        // commitDelta reports failures through handleError without
        // applying — intersect with the document so the selection only
        // ever names shapes that actually exist.
        let landed = Set(documentShapes().map(\.id))
        selectedShapeIDs = Set(copies.map(\.id)).intersection(landed)
        selectedInstanceID = nil
    }

    /// Rotates the selection a quarter turn about the grid-snapped center
    /// of its combined bounding box, preserving shape identity.
    public func rotateSelectedShapes(clockwise: Bool = true) {
        transformSelectedShapes { geometry, pivot in
            geometry.rotated90(around: pivot, clockwise: clockwise)
        }
    }

    /// Mirrors the selection across an axis through the grid-snapped
    /// center of its combined bounding box, preserving shape identity.
    public func mirrorSelectedShapes(across axis: LayoutMirrorAxis) {
        transformSelectedShapes { geometry, pivot in
            geometry.mirrored(across: axis, through: pivot)
        }
    }

    /// Applies an ID-preserving geometric transform about the selection's
    /// grid-snapped bounding-box center as one discrete edit.
    private func transformSelectedShapes(
        _ transform: (LayoutGeometry, LayoutPoint) -> LayoutGeometry
    ) {
        let shapes = selectedShapes()
        guard let first = shapes.first else { return }
        var combined = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        for shape in shapes.dropFirst() {
            combined = combined.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        let pivot = snapToGrid(combined.center)
        let updated = shapes.map { shape in
            var copy = shape
            copy.geometry = transform(shape.geometry, pivot)
            return copy
        }
        commitDelta(LayoutEditDelta(updatedShapes: updated))
    }

    // MARK: - Interactive Drag (DRD)

    /// Whether an interactive shape drag is in progress.
    public var isDraggingShapes: Bool { dragOriginShapes != nil }

    /// Starts an interactive drag of the selected shapes. The whole drag
    /// collapses into one undo step; in `observe`/`enforce` mode every
    /// tick re-verifies through the live session.
    ///
    /// With `duplicating` (Option-drag), fresh copies of the selection are
    /// added in place and the drag moves the copies while the originals
    /// stay put. Copies keep their net assignment, so a copied labeled
    /// wire honestly reports as an open until it is wired up.
    public func beginShapeDrag(duplicating: Bool = false) {
        guard dragOriginShapes == nil, activeHandleDrag == nil else { return }
        let shapes = selectedShapes()
        guard !shapes.isEmpty else { return }
        editor.recordUndoBoundary()
        var dragged = shapes
        if duplicating {
            let copies = shapes.map { shape in
                LayoutShape(
                    layer: shape.layer,
                    netID: shape.netID,
                    geometry: shape.geometry,
                    properties: shape.properties
                )
            }
            commitDelta(LayoutEditDelta(addedShapes: copies), transient: true)
            // commitDelta reports failures through handleError without
            // applying — only start the drag if the copies actually landed.
            let copyIDs = Set(copies.map(\.id))
            guard copyIDs.isSubset(of: Set(documentShapes().map(\.id))) else { return }
            selectedShapeIDs = copyIDs
            dragged = copies
            dragIsDuplicating = true
        }
        dragOriginShapes = dragged
        // The DRD session verifies against the top-context DRC mirror,
        // which cannot take child-space deltas; in-place drags fall back
        // to the plain path with verification deferred to the gesture end.
        if !isEditingInPlace, let liveDRC {
            dragSession = DRDDragSession(session: liveDRC, shapes: dragged, grid: gridSize)
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
            applied = snapToGrid(editVector(offset))
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
        dragIsDuplicating = false
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            runDRC()
        }
    }

    /// Aborts the drag. A move drag restores the dragged shapes to their
    /// origin; a duplicating drag removes the copies it added.
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
        if dragIsDuplicating {
            commitDelta(LayoutEditDelta(removedShapeIDs: origin.map(\.id)), transient: true)
            selectedShapeIDs.subtract(origin.map(\.id))
        } else {
            mirrorDragOffset(.zero, origin: origin)
        }
        dragOriginShapes = nil
        dragSession = nil
        dragOutcome = nil
        dragIsDuplicating = false
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            runDRC()
        }
    }

    /// Mirrors the drag position into the document as a transient edit so
    /// the canvas renders from the same state the live session verified.
    private func mirrorDragOffset(_ offset: LayoutPoint, origin: [LayoutShape]) {
        guard let cellID = editTargetCellID else { return }
        let moved = origin.map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: offset)
            return copy
        }
        do {
            try editor.performTransient { doc in
                try applyDelta(LayoutEditDelta(updatedShapes: moved), to: &doc, cellID: cellID)
            }
            for shape in moved {
                activeShapesByID[shape.id] = shape
            }
        } catch {
            handleError(error)
            return
        }
        if isEditingInPlace {
            // Child-space ticks redraw the fan-out immediately; the
            // verdicts are declared stale until the gesture ends.
            inPlaceVerificationPending = true
            rebuildRenderIndex()
            return
        }
        // The DRC side of the drag verifies through DRDDragSession; the
        // connectivity, constraint, and render-index views follow the
        // document directly so they stay live during the gesture.
        applyConnectivityDelta(LayoutEditDelta(updatedShapes: moved))
        applyConstraintDelta(LayoutEditDelta(updatedShapes: moved))
        applyLVSDelta(LayoutEditDelta(updatedShapes: moved))
        applyRenderIndexDelta(LayoutEditDelta(updatedShapes: moved))
    }

    // MARK: - Handle Editing (Stretch / Vertex)

    /// Whether a handle drag is in progress.
    public var isDraggingHandle: Bool { activeHandleDrag != nil }

    /// Starts dragging one handle of a shape — the stretch/vertex-edit
    /// gesture. The whole drag collapses into one undo step and every
    /// tick verifies through the live sessions. Returns false when the
    /// handle does not exist on that shape's geometry.
    @discardableResult
    public func beginHandleDrag(shapeID: UUID, handle: LayoutShapeHandle) -> Bool {
        guard activeHandleDrag == nil, dragOriginShapes == nil else { return false }
        guard let cellID = editTargetCellID,
              let cell = editor.document.cell(withID: cellID),
              let shape = cell.shapes.first(where: { $0.id == shapeID }) else { return false }
        // Validate the handle against the geometry before recording any
        // gesture state.
        guard LayoutHandleEditor.apply(
            handle, offset: .zero, to: shape.geometry, minimumSize: gridSize
        ) != nil else { return false }
        editor.recordUndoBoundary()
        activeHandleDrag = (shapeID: shapeID, handle: handle)
        handleOriginShape = shape
        return true
    }

    /// Moves the dragged handle to a cumulative offset from the gesture
    /// origin. The geometry is recomputed from the origin shape each tick
    /// so the drag is replayable and cancel restores exactly.
    public func updateHandleDrag(to offset: LayoutPoint) {
        guard let drag = activeHandleDrag, let origin = handleOriginShape else { return }
        guard let geometry = LayoutHandleEditor.apply(
            drag.handle,
            offset: snapToGrid(editVector(offset)),
            to: origin.geometry,
            minimumSize: gridSize
        ) else { return }
        var moved = origin
        moved.geometry = geometry
        commitDelta(LayoutEditDelta(updatedShapes: [moved]), transient: true)
    }

    /// Ends the handle drag at its current geometry and re-verifies the
    /// deferred tier so the snapshot is exact again.
    public func endHandleDrag() {
        guard activeHandleDrag != nil else { return }
        activeHandleDrag = nil
        handleOriginShape = nil
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            runDRC()
        }
    }

    /// Aborts the handle drag and restores the shape's origin geometry.
    public func cancelHandleDrag() {
        guard activeHandleDrag != nil, let origin = handleOriginShape else { return }
        activeHandleDrag = nil
        handleOriginShape = nil
        commitDelta(LayoutEditDelta(updatedShapes: [origin]), transient: true)
        if isEditingInPlace {
            resyncAfterInPlaceEdit()
        } else if let liveDRC {
            violations = liveDRC.commit().violations
            staleViolationKinds = []
        } else {
            runDRC()
        }
    }

}
