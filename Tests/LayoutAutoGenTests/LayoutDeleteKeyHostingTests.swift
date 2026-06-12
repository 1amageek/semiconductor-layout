import Foundation
import Testing
import LayoutCore
@testable import LayoutEditor

/// Guards the two halves of "pressing ⌫ deletes the selected layout
/// element": the model-layer delete path, and the canvas modifier
/// ordering that key delivery depends on.
///
/// The ordering half cannot be exercised in-process: SwiftUI only
/// dispatches key events under a running `NSApplication` event loop with
/// the app active, which a test bundle does not have (synthetic events
/// sent through a hosted `NSWindow` reach AppKit but never `onKeyPress`).
/// It was verified empirically with a standalone probe app driven by real
/// HID key events: a handler applied *inside* `.focusable()` receives no
/// keys at all — keys dispatch from the focused view outward — while the
/// same handler applied *outside* receives every key. The source-order
/// test below pins that arrangement.
@Suite("Layout Delete Key Tests")
@MainActor
struct LayoutDeleteKeyHostingTests {

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

    /// `.focusable()` must come before `.onKeyPress` in the canvas
    /// modifier chain. Reversed, every canvas key feature (Delete, arrow
    /// nudge, tool shortcuts) silently dies with no in-process test able
    /// to notice, so the arrangement is pinned at the source level.
    @Test func canvasAppliesOnKeyPressOutsideFocusable() throws {
        let canvasSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LayoutAutoGenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/LayoutEditor/LayoutCanvasView.swift")
        let source = try String(contentsOf: canvasSource, encoding: .utf8)

        let focusable = try #require(
            source.range(of: ".focusable()"),
            "LayoutCanvasView must declare the canvas focusable"
        )
        let keyPress = try #require(
            source.range(of: ".onKeyPress"),
            "LayoutCanvasView must handle key presses"
        )
        #expect(
            focusable.lowerBound < keyPress.lowerBound,
            ".onKeyPress must be applied after .focusable(): key events dispatch from the focused view outward, so a handler inside .focusable() never receives any key"
        )
    }
}
