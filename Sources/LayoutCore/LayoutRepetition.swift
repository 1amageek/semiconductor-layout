import Foundation

public struct LayoutRepetition: Hashable, Sendable, Codable {
    public var columns: Int
    public var rows: Int
    public var columnStep: LayoutPoint
    public var rowStep: LayoutPoint

    public init(
        columns: Int,
        rows: Int,
        columnStep: LayoutPoint,
        rowStep: LayoutPoint
    ) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.columnStep = columnStep
        self.rowStep = rowStep
    }
}
