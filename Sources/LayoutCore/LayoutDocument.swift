import Foundation

public struct LayoutDocument: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var units: LayoutUnits
    public var cells: [LayoutCell]
    public var topCellID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        units: LayoutUnits = .defaultUnits,
        cells: [LayoutCell] = [],
        topCellID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.units = units
        self.cells = cells
        self.topCellID = topCellID
    }

    public func cell(withID id: UUID) -> LayoutCell? {
        cells.first { $0.id == id }
    }

    public mutating func updateCell(_ cell: LayoutCell) {
        if let index = cells.firstIndex(where: { $0.id == cell.id }) {
            cells[index] = cell
        } else {
            cells.append(cell)
        }
    }
}
