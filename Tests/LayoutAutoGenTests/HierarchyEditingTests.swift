import Testing
import LayoutCore
import LayoutEditor

@MainActor
@Suite("Hierarchy editing")
struct HierarchyEditingTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    @Test func repetitionFlattenMatchesExplodedInstances() {
        let child = LayoutCell(name: "UNIT", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: .zero,
                    size: LayoutSize(width: 1, height: 1)
                ))
            )
        ])
        let repeated = LayoutInstance(
            cellID: child.id,
            name: "XA",
            repetition: LayoutRepetition(
                columns: 3,
                rows: 2,
                columnStep: LayoutPoint(x: 2, y: 0),
                rowStep: LayoutPoint(x: 0, y: 3)
            )
        )
        let top = LayoutCell(name: "TOP", instances: [repeated])
        let compact = LayoutDocument(name: "compact", cells: [child, top], topCellID: top.id)
        let compactBoxes = flattenedBoxes(compact)

        let explodedInstances = repeated.occurrenceTransforms().enumerated().map { index, transform in
            LayoutInstance(cellID: child.id, name: "XA_\(index)", transform: transform)
        }
        let explodedTop = LayoutCell(name: "TOP", instances: explodedInstances)
        let exploded = LayoutDocument(name: "exploded", cells: [child, explodedTop], topCellID: explodedTop.id)

        #expect(compactBoxes == flattenedBoxes(exploded))
    }

    @Test func instanceMoveAndUndoUpdateFlattenedBounds() {
        let child = LayoutCell(name: "UNIT", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: .zero,
                    size: LayoutSize(width: 1, height: 1)
                ))
            )
        ])
        let instance = LayoutInstance(cellID: child.id, name: "X1")
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(name: "hier", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        viewModel.selectedInstanceID = instance.id
        viewModel.moveSelectedInstance(by: LayoutPoint(x: 2, y: 3))
        #expect(flattenedBoxes(viewModel.editor.document).first?.origin == LayoutPoint(x: 2, y: 3))

        viewModel.undo()
        #expect(flattenedBoxes(viewModel.editor.document).first?.origin == .zero)
    }

    @Test func explodeArrayReplacesRepetitionWithIndividualInstances() {
        let child = LayoutCell(name: "UNIT", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: .zero,
                    size: LayoutSize(width: 1, height: 1)
                ))
            )
        ])
        let repeated = LayoutInstance(
            cellID: child.id,
            name: "XA",
            repetition: LayoutRepetition(
                columns: 2,
                rows: 2,
                columnStep: LayoutPoint(x: 2, y: 0),
                rowStep: LayoutPoint(x: 0, y: 2)
            )
        )
        let top = LayoutCell(name: "TOP", instances: [repeated])
        let document = LayoutDocument(name: "hier", cells: [child, top], topCellID: top.id)
        let before = flattenedBoxes(document)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        viewModel.selectedInstanceID = repeated.id
        viewModel.explodeSelectedInstanceArray()

        let cell = viewModel.editor.document.cell(withID: top.id)
        #expect(cell?.instances.count == 4)
        #expect(cell?.instances.allSatisfy { $0.repetition == nil } == true)
        #expect(flattenedBoxes(viewModel.editor.document) == before)
    }

    // MARK: - Edit in place

    /// Two occurrences of UNIT; editing one IN PLACE must move the shape
    /// in BOTH occurrences (the fan-out is through the shared cell), and
    /// the result must equal editing the child cell directly.
    @Test func inPlaceEditFansOutToEveryOccurrenceAndMatchesDirectChildEdit() throws {
        let childShape = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        let child = LayoutCell(name: "UNIT", shapes: [childShape])
        let a = LayoutInstance(
            cellID: child.id,
            name: "XA",
            transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 0))
        )
        let b = LayoutInstance(
            cellID: child.id,
            name: "XB",
            transform: LayoutTransform(translation: LayoutPoint(x: 0, y: 20), rotation: .deg90)
        )
        let top = LayoutCell(name: "TOP", instances: [a, b])
        let document = LayoutDocument(name: "eip", cells: [child, top], topCellID: top.id)

        // Reference: edit the child cell directly.
        let reference = LayoutEditorViewModel(document: document, tech: .standard())
        reference.openCell(child.id)
        reference.selectedShapeIDs = [childShape.id]
        reference.moveSelectedShapes(by: LayoutPoint(x: 2, y: 3))
        reference.navigateBack()
        let referenceBoxes = sortedBoxes(reference.flattenedDocumentShapes())

        // In place: same edit through the XA occurrence, with the move
        // vector given in VIEW space (XA is translation-only, so the view
        // vector equals the child vector).
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        viewModel.enterInPlaceEdit(instanceID: a.id)
        #expect(viewModel.isEditingInPlace)
        #expect(viewModel.editTargetCellID == child.id)
        viewModel.selectedShapeIDs = [childShape.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 2, y: 3))

        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == referenceBoxes)
        #expect(!viewModel.inPlaceVerificationPending, "discrete edits re-verify immediately")
        viewModel.exitInPlaceEdit()
        #expect(!viewModel.isEditingInPlace)
        viewModel.undo()
        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == flattenedBoxes(document))
    }

    /// Pointer input maps through a rotated occurrence: adding a rectangle
    /// at view-space coordinates inside the rotated instance must land at
    /// the inverse-mapped child coordinates.
    @Test func inPlaceAddMapsPointerThroughTheRotatedOccurrence() throws {
        let child = LayoutCell(name: "UNIT", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
            )
        ])
        let rotated = LayoutInstance(
            cellID: child.id,
            name: "XR",
            transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 0), rotation: .deg90)
        )
        let top = LayoutCell(name: "TOP", instances: [rotated])
        let document = LayoutDocument(name: "eip", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        viewModel.enterInPlaceEdit(instanceID: rotated.id)
        // View-space corners (8, 2) and (6, 5): under T = translate(10,0) +
        // rot90, local = rot(-90)(p - (10,0)) → (2,2) and (5,4).
        viewModel.addRectangle(from: LayoutPoint(x: 8, y: 2), to: LayoutPoint(x: 6, y: 5))

        let childCell = try #require(viewModel.editor.document.cell(withID: child.id))
        #expect(childCell.shapes.count == 2)
        let added = try #require(childCell.shapes.last)
        let box = LayoutGeometryAnalysis.boundingBox(for: added.geometry)
        #expect(abs(box.minX - 2) < 1e-9)
        #expect(abs(box.minY - 2) < 1e-9)
        #expect(abs(box.maxX - 5) < 1e-9)
        #expect(abs(box.maxY - 4) < 1e-9)
    }

    @Test func inPlaceEditOnArrayedInstanceIsRefused() {
        let child = LayoutCell(name: "UNIT")
        let arrayed = LayoutInstance(
            cellID: child.id,
            name: "XA",
            repetition: LayoutRepetition(
                columns: 2, rows: 1,
                columnStep: LayoutPoint(x: 2, y: 0),
                rowStep: LayoutPoint(x: 0, y: 2)
            )
        )
        let top = LayoutCell(name: "TOP", instances: [arrayed])
        let document = LayoutDocument(name: "eip", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        viewModel.enterInPlaceEdit(instanceID: arrayed.id)

        #expect(!viewModel.isEditingInPlace)
        #expect(viewModel.lastError != nil)
    }

    @Test func undoThatRemovesTheEnteredInstanceDropsTheInPlaceContext() throws {
        let child = LayoutCell(name: "UNIT", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
            )
        ])
        let top = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "eip", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        viewModel.placeInstance(cellID: child.id, name: "X0", at: .zero)
        let instanceID = try #require(viewModel.editor.document.cell(withID: top.id)?.instances.first?.id)
        viewModel.enterInPlaceEdit(instanceID: instanceID)
        #expect(viewModel.isEditingInPlace)

        viewModel.undo()

        #expect(!viewModel.isEditingInPlace, "a dangling in-place context must drop, not dangle")
    }

    // MARK: - Flatten / make-cell verbs

    @Test func flattenSelectedInstanceMaterializesTheSubtreeExactly() throws {
        let grandchild = LayoutCell(name: "LEAF", shapes: [
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.5)))
            )
        ])
        let child = LayoutCell(
            name: "UNIT",
            shapes: [
                LayoutShape(
                    layer: m1,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 2, height: 2)))
                )
            ],
            instances: [
                LayoutInstance(
                    cellID: grandchild.id,
                    name: "L0",
                    transform: LayoutTransform(translation: LayoutPoint(x: 3, y: 0), rotation: .deg90)
                )
            ]
        )
        let instance = LayoutInstance(
            cellID: child.id,
            name: "X0",
            transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 5))
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(
            name: "flatten",
            cells: [grandchild, child, top],
            topCellID: top.id
        )
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        let before = sortedBoxes(viewModel.flattenedDocumentShapes())

        viewModel.selectedInstanceID = instance.id
        viewModel.flattenSelectedInstance()

        let topCell = try #require(viewModel.editor.document.cell(withID: top.id))
        #expect(topCell.instances.isEmpty)
        #expect(topCell.shapes.count == 2, "child shape + grandchild shape materialize")
        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == before)
        #expect(
            viewModel.editor.document.cell(withID: child.id) != nil,
            "flatten copies content; the source cell stays"
        )

        viewModel.undo()
        #expect(viewModel.editor.document.cell(withID: top.id)?.instances.count == 1)
        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == before)
    }

    @Test func makeCellFromSelectionIsTheInverseOfFlatten() throws {
        let kept = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        let groupedA = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3, y: 0),
                size: LayoutSize(width: 1, height: 2)
            ))
        )
        let groupedB = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 5, y: 1),
                size: LayoutSize(width: 2, height: 1)
            ))
        )
        let top = LayoutCell(name: "TOP", shapes: [kept, groupedA, groupedB])
        let document = LayoutDocument(name: "group", cells: [top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        let before = sortedBoxes(viewModel.flattenedDocumentShapes())

        viewModel.selectedShapeIDs = [groupedA.id, groupedB.id]
        let newCellID = viewModel.makeCellFromSelection(name: "GROUP")

        #expect(newCellID != nil)
        let topCell = try #require(viewModel.editor.document.cell(withID: top.id))
        #expect(topCell.shapes.count == 1)
        #expect(topCell.instances.count == 1)
        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == before)

        // The new instance is selected; flattening it restores the host.
        viewModel.flattenSelectedInstance()
        let restored = try #require(viewModel.editor.document.cell(withID: top.id))
        #expect(restored.shapes.count == 3)
        #expect(restored.instances.isEmpty)
        #expect(sortedBoxes(viewModel.flattenedDocumentShapes()) == before)
    }

    @Test func placeInstanceSurfacesCycleRejection() {
        let child = LayoutCell(name: "UNIT")
        let instance = LayoutInstance(cellID: child.id, name: "X1")
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(name: "hier", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        // Placing TOP inside UNIT would close the loop TOP -> UNIT -> TOP.
        viewModel.openCell(child.id)
        viewModel.placeInstance(cellID: top.id, name: "loop", at: .zero)

        #expect(viewModel.lastError != nil)
        #expect(viewModel.editor.document.cell(withID: child.id)?.instances.isEmpty == true)
    }

    private func flattenedBoxes(_ document: LayoutDocument) -> [LayoutRect] {
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        return sortedBoxes(viewModel.flattenedDocumentShapes())
    }

    private func sortedBoxes(_ shapes: [LayoutShape]) -> [LayoutRect] {
        shapes
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
            .sorted { lhs, rhs in
                if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                if lhs.size.width != rhs.size.width { return lhs.size.width < rhs.size.width }
                return lhs.size.height < rhs.size.height
            }
    }
}
