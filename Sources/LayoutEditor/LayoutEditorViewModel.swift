import SwiftUI
import LayoutCore
import LayoutTech
import LayoutVerify

@Observable
@MainActor
public final class LayoutEditorViewModel {
    public var editor: LayoutDocumentEditor
    public var tech: LayoutTechDatabase
    public var tool: LayoutTool = .select
    public var activeLayer: LayoutLayerID
    public var activeViaID: String
    public var zoom: CGFloat = 1.0
    public var offset: CGSize = .zero
    public var gridSize: Double = 0.1
    public var selectedShapeIDs: Set<UUID> = []
    public var violations: [LayoutViolation] = []
    public var lastError: String?

    public init(tech: LayoutTechDatabase = .standard()) {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "Layout", cells: [cell], topCellID: cell.id)
        self.editor = LayoutDocumentEditor(document: document)
        self.tech = tech
        self.activeLayer = tech.layers.first?.id ?? LayoutLayerID(name: "M1", purpose: "drawing")
        self.activeViaID = tech.vias.first?.id ?? "VIA1"
    }

    public var activeCellID: UUID? {
        editor.document.topCellID
    }

    public func runDRC() {
        let service = LayoutDRCService()
        violations = service.run(document: editor.document, tech: tech).violations
    }

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

    public func addPath(points: [LayoutPoint], width: Double) {
        guard let cellID = activeCellID else { return }
        let path = LayoutPath(points: points, width: width)
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

    public func selectShape(at point: LayoutPoint) {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return
        }
        for shape in cell.shapes.reversed() {
            if LayoutGeometryUtils.contains(point, in: shape.geometry) {
                selectedShapeIDs = [shape.id]
                return
            }
        }
        selectedShapeIDs.removeAll()
    }

    public func documentShapes() -> [LayoutShape] {
        guard let cellID = activeCellID, let cell = editor.document.cell(withID: cellID) else {
            return []
        }
        return cell.shapes
    }

    private func handleError(_ error: Error) {
        lastError = error.localizedDescription
    }
}
