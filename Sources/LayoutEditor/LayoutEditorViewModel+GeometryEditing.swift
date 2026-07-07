import SwiftUI
import LayoutCore
import LayoutIR
import LayoutVerify
import MaskGeometry

extension LayoutEditorViewModel {
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
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            // The canvas has not been laid out yet; defer via canvasSize.didSet
            // so the fit is not silently lost while the editor is off screen.
            pendingFitAll = true
            zoom = 1.0
            offset = .zero
            return
        }
        guard let bounds = contentBounds(),
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

    /// Removes the selected instance from its host cell. Instance edits
    /// are not expressible as a shape delta, so this goes through the
    /// document editor (one undo unit) and re-syncs the live sessions —
    /// the same path every other instance edit uses.
    public func deleteSelectedInstance() {
        guard let hostCellID = editTargetCellID, let selectedInstanceID else { return }
        do {
            try editor.removeInstance(id: selectedInstanceID, from: hostCellID)
            self.selectedInstanceID = nil
            resyncAfterInstanceEdit()
        } catch {
            handleError(error)
        }
    }

    /// Deletes whatever is selected — shapes when any, otherwise the
    /// selected instance. The single entry point for the Delete key and
    /// the Edit menu.
    public func deleteSelection() {
        if !selectedShapeIDs.isEmpty {
            deleteSelectedShapes()
        } else if selectedInstanceID != nil {
            deleteSelectedInstance()
        }
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
    }}
