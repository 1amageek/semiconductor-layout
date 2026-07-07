import Foundation
import LayoutCore

extension LayoutEditorViewModel {
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

    public func placeInstance(cellID childCellID: UUID, name: String, at point: LayoutPoint) {
        guard let parentCellID = editTargetCellID else { return }
        guard canPlaceInstance(childCellID: childCellID, in: parentCellID) else {
            handleError(LayoutCoreError.instanceCycle(
                parentCellID: parentCellID,
                childCellID: childCellID
            ))
            return
        }
        let instance = LayoutInstance(
            cellID: childCellID,
            name: name,
            transform: LayoutTransform(
                translation: isEditingInPlace ? editPoint(point) : snapToGrid(point)
            )
        )
        do {
            try editor.addInstance(instance, to: parentCellID)
            selectedInstanceID = instance.id
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    public func moveSelectedInstance(by delta: LayoutPoint) {
        let delta = editVector(delta)
        transformSelectedInstance { transform in
            transform.translation = transform.translation.translated(by: snapToGrid(delta))
        }
    }

    public func rotateSelectedInstance(by degrees: Double = 90) {
        transformSelectedInstance { transform in
            transform.rotationDegrees += degrees
        }
    }

    public func mirrorSelectedInstance(x: Bool = true, y: Bool = false) {
        transformSelectedInstance { transform in
            if x { transform.mirrorX.toggle() }
            if y { transform.mirrorY.toggle() }
        }
    }

    public func explodeSelectedInstanceArray() {
        guard let hostCellID = editTargetCellID,
              let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = cell.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                let instance = cell.instances[index]
                guard instance.repetition != nil else { return }
                let exploded = instance.occurrenceTransforms().enumerated().map { offset, transform in
                    LayoutInstance(
                        cellID: instance.cellID,
                        name: "\(instance.name)_\(offset)",
                        transform: transform,
                        terminalNetIDs: instance.terminalNetIDs
                    )
                }
                cell.instances.remove(at: index)
                cell.instances.insert(contentsOf: exploded, at: index)
                doc.updateCell(cell)
            }
            self.selectedInstanceID = nil
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Materializes the selected instance into its host cell: the
    /// instance's entire subtree (shapes, vias, labels, pins; arrays
    /// expanded) lands as plain host content with FRESH identities —
    /// multi-instanced children share UUIDs that would collide once
    /// materialized side by side, so minting new IDs is explicit policy.
    /// One undo unit; the flattened document geometry is unchanged.
    public func flattenSelectedInstance() {
        guard let hostCellID = editTargetCellID, let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var host = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = host.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                let instance = host.instances[index]
                guard let child = doc.cell(withID: instance.cellID) else {
                    throw LayoutCoreError.cellNotFound(instance.cellID)
                }
                var content = FlattenedContent()
                for transform in instance.occurrenceTransforms() {
                    Self.collectFlattenedContent(
                        of: child,
                        in: doc,
                        transforms: [transform],
                        depth: 0,
                        into: &content
                    )
                }
                host.shapes.append(contentsOf: content.shapes)
                host.vias.append(contentsOf: content.vias)
                host.labels.append(contentsOf: content.labels)
                host.pins.append(contentsOf: content.pins)
                host.instances.remove(at: index)
                doc.updateCell(host)
            }
            self.selectedInstanceID = nil
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Replaces the selected shapes with a new cell plus an
    /// identity-transform instance of it — the inverse of flatten for a
    /// same-cell selection. The shapes keep their geometry and identities
    /// inside the new cell, so the flattened document is unchanged.
    @discardableResult
    public func makeCellFromSelection(name: String) -> UUID? {
        guard let hostCellID = editTargetCellID else { return nil }
        let shapes = selectedShapes()
        guard !shapes.isEmpty else { return nil }
        var newInstanceID: UUID?
        var newCellID: UUID?
        do {
            try editor.perform { doc in
                guard var host = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                let ids = Set(shapes.map(\.id))
                let newCell = LayoutCell(name: name, shapes: shapes)
                let instance = LayoutInstance(cellID: newCell.id, name: name)
                host.shapes.removeAll { ids.contains($0.id) }
                host.instances.append(instance)
                doc.cells.append(newCell)
                doc.updateCell(host)
                newInstanceID = instance.id
                newCellID = newCell.id
            }
        } catch {
            handleError(error)
            return nil
        }
        selectedShapeIDs.removeAll()
        selectedInstanceID = newInstanceID
        resyncAfterInstanceEdit()
        return newCellID
    }

    struct FlattenedContent {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var labels: [LayoutLabel] = []
        var pins: [LayoutPin] = []
    }

    /// Deep flatten of one cell subtree with fresh identities. Transform
    /// composition matches the verification flatten: geometry through the
    /// chain innermost-first; via/label/pin positions point-transformed
    /// (a via's cut is its definition's, so only its anchor moves — the
    /// same convention every verification flatten in this package uses).
    static func collectFlattenedContent(
        of cell: LayoutCell,
        in document: LayoutDocument,
        transforms: [LayoutTransform],
        terminalNetIDs: [String: UUID] = [:],
        depth: Int,
        into content: inout FlattenedContent
    ) {
        guard depth < 10 else { return }
        func mapPoint(_ point: LayoutPoint) -> LayoutPoint {
            var mapped = point
            for transform in transforms.reversed() {
                mapped = transform.apply(to: mapped)
            }
            return mapped
        }
        for shape in cell.shapes {
            var geometry = shape.geometry
            for transform in transforms.reversed() {
                geometry = geometry.transformed(by: transform)
            }
            content.shapes.append(LayoutShape(
                layer: shape.layer,
                netID: shape.netID,
                geometry: geometry,
                properties: shape.properties
            ))
        }
        for via in cell.vias {
            content.vias.append(LayoutVia(
                viaDefinitionID: via.viaDefinitionID,
                position: mapPoint(via.position),
                netID: via.netID
            ))
        }
        for label in cell.labels {
            content.labels.append(LayoutLabel(
                text: label.text,
                position: mapPoint(label.position),
                layer: label.layer
            ))
        }
        for pin in cell.pins {
            content.pins.append(LayoutPin(
                name: pin.name,
                position: mapPoint(pin.position),
                size: pin.size,
                layer: pin.layer,
                // The instance terminal binding overrides the child
                // pin's own net at this occurrence — same semantics as
                // the connectivity flatten.
                netID: terminalNetIDs[pin.name] ?? pin.netID,
                role: pin.role
            ))
        }
        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            for occurrence in instance.occurrenceTransforms() {
                collectFlattenedContent(
                    of: child,
                    in: document,
                    transforms: transforms + [occurrence],
                    terminalNetIDs: instance.terminalNetIDs,
                    depth: depth + 1,
                    into: &content
                )
            }
        }
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

    private func transformSelectedInstance(_ update: (inout LayoutTransform) -> Void) {
        guard let hostCellID = editTargetCellID,
              let selectedInstanceID else { return }
        do {
            try editor.perform { doc in
                guard var cell = doc.cell(withID: hostCellID) else {
                    throw LayoutCoreError.cellNotFound(hostCellID)
                }
                guard let index = cell.instances.firstIndex(where: { $0.id == selectedInstanceID }) else {
                    throw LayoutCoreError.instanceNotFound(selectedInstanceID)
                }
                update(&cell.instances[index].transform)
                doc.updateCell(cell)
            }
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    static func boundingBox(of points: [LayoutPoint]) -> LayoutRect {
        var minX = points[0].x
        var maxX = points[0].x
        var minY = points[0].y
        var maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    func resyncAfterInstanceEdit() {
        inPlaceVerificationPending = false
        resyncLiveDRC()
        resyncLiveConnectivity()
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    func canPlaceInstance(childCellID: UUID, in parentCellID: UUID) -> Bool {
        guard childCellID != parentCellID else { return false }
        return !cellCanReach(childCellID, target: parentCellID, visited: [])
    }

    private func cellCanReach(_ source: UUID, target: UUID, visited: Set<UUID>) -> Bool {
        guard !visited.contains(source),
              let cell = editor.document.cell(withID: source) else { return false }
        if cell.instances.contains(where: { $0.cellID == target }) {
            return true
        }
        var nextVisited = visited
        nextVisited.insert(source)
        return cell.instances.contains { instance in
            cellCanReach(instance.cellID, target: target, visited: nextVisited)
        }
    }

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
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
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
        refreshConstraintViolations()
        resyncLiveLVS()
        rebuildRenderIndex()
    }

    static func initialNavigationPath(document: LayoutDocument, activeCellID: UUID?) -> [UUID] {
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

    static func cellBoundingBox(
        _ cell: LayoutCell,
        in document: LayoutDocument
    ) -> LayoutRect {
        var visited: Set<UUID> = []
        return cellBoundingBox(cell, in: document, visited: &visited)
    }

    private static func cellBoundingBox(
        _ cell: LayoutCell,
        in document: LayoutDocument,
        visited: inout Set<UUID>
    ) -> LayoutRect {
        guard visited.insert(cell.id).inserted else { return .zero }
        defer { visited.remove(cell.id) }

        var bbox: LayoutRect?
        for shape in cell.shapes {
            let shapeBox = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            bbox = bbox.map { $0.union(shapeBox) } ?? shapeBox
        }
        for instance in cell.instances {
            guard let child = document.cell(withID: instance.cellID) else { continue }
            let childBox = cellBoundingBox(child, in: document, visited: &visited)
            guard childBox.size.width > 0, childBox.size.height > 0 else { continue }
            for transform in instance.occurrenceTransforms() {
                let transformed = transformRect(childBox, by: transform)
                bbox = bbox.map { $0.union(transformed) } ?? transformed
            }
        }
        return bbox ?? .zero
    }

    static func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
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

}
