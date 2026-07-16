import Foundation
import Testing
import LayoutCore
@testable import LayoutEditor

/// Verifies the model API invoked by the canvas Delete key for each
/// selectable layout element.
@Suite("Layout Delete Selection Tests")
@MainActor
struct LayoutDeleteSelectionTests {

    @Test func deleteSelectionRemovesSelectedShape() throws {
        let viewModel = LayoutEditorViewModel()
        viewModel.addRectangle(
            from: LayoutPoint(x: 0, y: 0),
            to: LayoutPoint(x: 100, y: 100)
        )
        let cellID = try #require(viewModel.activeCellID)
        let shapeID = try #require(
            viewModel.editor.document.cell(withID: cellID)?.shapes.first?.id
        )
        viewModel.selectedShapeIDs = [shapeID]

        viewModel.deleteSelection()

        let shapes = viewModel.editor.document.cell(withID: cellID)?.shapes ?? []
        #expect(shapes.isEmpty, "deleteSelection must remove the selected shape")
        #expect(viewModel.lastError == nil)
        #expect(viewModel.selectedShapeIDs.isEmpty)
    }

    @Test func deleteSelectionRemovesSelectedInstance() throws {
        let viewModel = LayoutEditorViewModel()
        let cellID = try #require(viewModel.activeCellID)

        var child = LayoutCell(name: "CHILD")
        child.shapes.append(LayoutShape(
            layer: viewModel.activeLayer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 50, height: 50)
            ))
        ))
        viewModel.editor.addCell(child)
        let instance = LayoutInstance(cellID: child.id, name: "X1")
        try viewModel.editor.addInstance(instance, to: cellID)
        viewModel.selectedInstanceID = instance.id

        viewModel.deleteSelection()

        let instances = viewModel.editor.document.cell(withID: cellID)?.instances ?? []
        #expect(instances.isEmpty, "deleteSelection must remove the selected instance")
        #expect(viewModel.lastError == nil)
        #expect(viewModel.selectedInstanceID == nil)
    }
}
