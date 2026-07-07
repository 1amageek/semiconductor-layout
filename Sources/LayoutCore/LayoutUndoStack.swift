import Foundation

public struct LayoutUndoStack: Sendable {
    private var undoStack: [LayoutUndoEntry] = []
    private var redoStack: [LayoutUndoEntry] = []
    private let maxDepth: Int

    public init(maxDepth: Int = 100) {
        self.maxDepth = maxDepth
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ document: LayoutDocument) {
        undoStack.append(.document(document))
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        redoStack.removeAll()
    }

    public mutating func recordCellElementUpdate(
        cellID: UUID,
        beforeShapes: [LayoutShape],
        afterShapes: [LayoutShape],
        beforeVias: [LayoutVia],
        afterVias: [LayoutVia]
    ) {
        undoStack.append(.cellElements(LayoutCellElementUndo(
            cellID: cellID,
            beforeShapes: beforeShapes,
            afterShapes: afterShapes,
            beforeVias: beforeVias,
            afterVias: afterVias
        )))
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        redoStack.removeAll()
    }

    public mutating func undo(current: LayoutDocument) -> LayoutDocument? {
        guard let entry = undoStack.popLast() else { return nil }
        switch entry {
        case .document(let previous):
            redoStack.append(.document(current))
            return previous
        case .cellElements(let update):
            redoStack.append(entry)
            return update.applyingBefore(to: current)
        }
    }

    public mutating func redo(current: LayoutDocument) -> LayoutDocument? {
        guard let entry = redoStack.popLast() else { return nil }
        switch entry {
        case .document(let next):
            undoStack.append(.document(current))
            return next
        case .cellElements(let update):
            undoStack.append(entry)
            return update.applyingAfter(to: current)
        }
    }
}

private enum LayoutUndoEntry: Sendable {
    case document(LayoutDocument)
    case cellElements(LayoutCellElementUndo)
}

private struct LayoutCellElementUndo: Sendable {
    var cellID: UUID
    var beforeShapes: [LayoutShape]
    var afterShapes: [LayoutShape]
    var beforeVias: [LayoutVia]
    var afterVias: [LayoutVia]

    func applyingBefore(to document: LayoutDocument) -> LayoutDocument {
        applying(shapes: beforeShapes, vias: beforeVias, to: document)
    }

    func applyingAfter(to document: LayoutDocument) -> LayoutDocument {
        applying(shapes: afterShapes, vias: afterVias, to: document)
    }

    private func applying(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        to document: LayoutDocument
    ) -> LayoutDocument {
        var document = document
        guard let cellIndex = document.cells.firstIndex(where: { $0.id == cellID }) else {
            return document
        }
        for shape in shapes {
            if let index = document.cells[cellIndex].shapes.firstIndex(where: { $0.id == shape.id }) {
                document.cells[cellIndex].shapes[index] = shape
            }
        }
        for via in vias {
            if let index = document.cells[cellIndex].vias.firstIndex(where: { $0.id == via.id }) {
                document.cells[cellIndex].vias[index] = via
            }
        }
        return document
    }
}
