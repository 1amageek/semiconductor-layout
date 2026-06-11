import Foundation

/// Typed failures of `LayoutConnectivityExtractor`.
public enum LayoutConnectivityExtractionError: Error, Equatable, Sendable {
    /// The document has no resolvable target cell.
    case targetCellNotFound
}
