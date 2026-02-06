import Foundation

public struct LayoutDocumentEditor: Sendable {
    public private(set) var document: LayoutDocument
    private var undoStack: LayoutUndoStack

    public init(document: LayoutDocument) {
        self.document = document
        self.undoStack = LayoutUndoStack()
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    public mutating func perform(_ body: (inout LayoutDocument) throws -> Void) rethrows {
        undoStack.record(document)
        try body(&document)
    }

    public mutating func undo() {
        if let previous = undoStack.undo(current: document) {
            document = previous
        }
    }

    public mutating func redo() {
        if let next = undoStack.redo(current: document) {
            document = next
        }
    }

    public mutating func addCell(_ cell: LayoutCell) {
        undoStack.record(document)
        document.updateCell(cell)
        if document.topCellID == nil {
            document.topCellID = cell.id
        }
    }

    public mutating func addShape(_ shape: LayoutShape, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.shapes.append(shape)
            doc.updateCell(cell)
        }
    }

    public mutating func updateShape(_ shape: LayoutShape, in cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
            doc.updateCell(cell)
        }
    }

    public mutating func removeShape(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.shapes.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.shapeNotFound(id)
            }
            cell.shapes.remove(at: index)
            doc.updateCell(cell)
        }
    }

    public mutating func addVia(_ via: LayoutVia, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.vias.append(via)
            doc.updateCell(cell)
        }
    }

    public mutating func removeVia(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.vias.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.viaNotFound(id)
            }
            cell.vias.remove(at: index)
            doc.updateCell(cell)
        }
    }

    public mutating func addLabel(_ label: LayoutLabel, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.labels.append(label)
            doc.updateCell(cell)
        }
    }

    public mutating func removeLabel(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.labels.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.labelNotFound(id)
            }
            cell.labels.remove(at: index)
            doc.updateCell(cell)
        }
    }

    public mutating func addPin(_ pin: LayoutPin, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.pins.append(pin)
            doc.updateCell(cell)
        }
    }

    public mutating func removePin(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.pins.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.pinNotFound(id)
            }
            cell.pins.remove(at: index)
            doc.updateCell(cell)
        }
    }

    public mutating func addInstance(_ instance: LayoutInstance, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.instances.append(instance)
            doc.updateCell(cell)
        }
    }

    public mutating func removeInstance(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.instances.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.instanceNotFound(id)
            }
            cell.instances.remove(at: index)
            doc.updateCell(cell)
        }
    }

    public mutating func addNet(_ net: LayoutNet, to cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            cell.nets.append(net)
            doc.updateCell(cell)
        }
    }

    public mutating func removeNet(id: UUID, from cellID: UUID) throws {
        try perform { doc in
            guard var cell = doc.cell(withID: cellID) else {
                throw LayoutCoreError.cellNotFound(cellID)
            }
            guard let index = cell.nets.firstIndex(where: { $0.id == id }) else {
                throw LayoutCoreError.netNotFound(id)
            }
            cell.nets.remove(at: index)
            doc.updateCell(cell)
        }
    }
}
