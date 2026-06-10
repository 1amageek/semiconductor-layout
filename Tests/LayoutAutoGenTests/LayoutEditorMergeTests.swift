import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutEditor

@Suite("Layout Editor Merge")
struct LayoutEditorMergeTests {

    @MainActor
    @Test("Merge uses boolean union instead of convex hull")
    func mergeUsesBooleanUnionInsteadOfConvexHull() {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let first = LayoutShape(
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 2, height: 1)
            ))
        )
        let second = LayoutShape(
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 1),
                size: LayoutSize(width: 1, height: 1)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [first, second])
        let document = LayoutDocument(
            name: "merge-test",
            cells: [cell],
            topCellID: cell.id
        )
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        viewModel.selectedShapeIDs = [first.id, second.id]

        viewModel.mergeSelectedShapes()

        let mergedShapes = viewModel.editor.document.cell(withID: cell.id)?.shapes ?? []
        let totalArea = mergedShapes.reduce(0.0) { partial, shape in
            partial + LayoutGeometryAnalysis.area(of: shape.geometry)
        }

        #expect(mergedShapes.allSatisfy { $0.layer == layer })
        #expect(abs(totalArea - 3.0) < 1e-9)
        #expect(!mergedShapes.contains { $0.id == first.id || $0.id == second.id })
    }
}
