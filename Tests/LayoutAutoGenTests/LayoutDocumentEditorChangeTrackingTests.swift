import Foundation
import LayoutCore
import Testing

@Suite("LayoutDocumentEditor Change Tracking")
struct LayoutDocumentEditorChangeTrackingTests {

    private func makeEditor() -> (LayoutDocumentEditor, UUID) {
        var document = LayoutDocument(name: "test")
        let cell = LayoutCell(name: "top")
        document.cells.append(cell)
        document.topCellID = cell.id
        return (LayoutDocumentEditor(document: document), cell.id)
    }

    private func makeShape() -> LayoutShape {
        LayoutShape(
            layer: LayoutLayerID(name: "M1", purpose: "drawing"),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 100, height: 100)
            ))
        )
    }

    @Test("A fresh editor has revision zero and no persisted baseline")
    func freshEditorState() {
        let (editor, _) = makeEditor()
        #expect(editor.revision == 0)
        #expect(!editor.isPersisted)
        #expect(editor.hasUnsavedChanges)
    }

    @Test("markSaved records the baseline and clears unsaved changes")
    func markSavedClearsChanges() {
        var (editor, _) = makeEditor()
        editor.markSaved()
        #expect(editor.isPersisted)
        #expect(!editor.hasUnsavedChanges)
    }

    @Test("Typed mutation helpers advance the revision")
    func typedHelperAdvancesRevision() throws {
        var (editor, cellID) = makeEditor()
        editor.markSaved()
        try editor.addShape(makeShape(), to: cellID)
        #expect(editor.revision > 0)
        #expect(editor.hasUnsavedChanges)
    }

    @Test("perform advances the revision")
    func performAdvancesRevision() {
        var (editor, _) = makeEditor()
        let before = editor.revision
        editor.perform { _ in }
        #expect(editor.revision > before)
    }

    @Test("Transient gesture mutations advance the revision")
    func transientAdvancesRevision() {
        var (editor, _) = makeEditor()
        editor.markSaved()
        editor.performTransient { _ in }
        #expect(editor.hasUnsavedChanges)
    }

    @Test("Undo counts as a change relative to the saved baseline")
    func undoStaysDirty() throws {
        var (editor, cellID) = makeEditor()
        try editor.addShape(makeShape(), to: cellID)
        editor.markSaved()
        editor.undo()
        #expect(editor.hasUnsavedChanges)
    }

    @Test("Undo with an empty stack does not mutate the document")
    func emptyUndoIsNotAChange() {
        var (editor, _) = makeEditor()
        editor.markSaved()
        editor.undo()
        #expect(!editor.hasUnsavedChanges)
    }

    @Test("recordUndoBoundary alone is not a change")
    func undoBoundaryIsNotAChange() {
        var (editor, _) = makeEditor()
        editor.markSaved()
        editor.recordUndoBoundary()
        #expect(!editor.hasUnsavedChanges)
    }
}
