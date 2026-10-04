import Foundation

/// Typed failures of `LayoutConnectivityExtractor`.
public enum LayoutConnectivityExtractionError: Error, Equatable, Sendable {
    /// The document has no resolvable target cell.
    case targetCellNotFound
    case ambiguousSourceIdentity(UUID)
    /// A production analysis lacks the owner needed to interpret its scoped references.
    case missingSourceSnapshot
}
