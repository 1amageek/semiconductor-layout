import Foundation
import LayoutCore
import LayoutVerify

extension LayoutEditorViewModel {
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
}
