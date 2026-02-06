import Foundation

public struct LayoutUndoStack: Sendable {
    private var undoStack: [LayoutDocument] = []
    private var redoStack: [LayoutDocument] = []
    private let maxDepth: Int

    public init(maxDepth: Int = 100) {
        self.maxDepth = maxDepth
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ document: LayoutDocument) {
        undoStack.append(document)
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        redoStack.removeAll()
    }

    public mutating func undo(current: LayoutDocument) -> LayoutDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: LayoutDocument) -> LayoutDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
