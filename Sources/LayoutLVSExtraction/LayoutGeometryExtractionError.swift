public enum LayoutGeometryExtractionError: Error, Sendable, Equatable {
    case topCellNotFound
    case missingReferencedCell(String)
    case recursiveHierarchy(String)
    case objectBudgetExceeded(limit: Int)
}
