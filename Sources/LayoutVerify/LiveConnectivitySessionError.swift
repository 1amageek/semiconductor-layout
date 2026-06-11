import Foundation

/// Typed failures of `LiveConnectivitySession`; every invalid input is
/// rejected explicitly instead of being absorbed into a wrong analysis.
public enum LiveConnectivitySessionError: Error, Equatable, Sendable {
    /// The document has no resolvable target cell.
    case targetCellNotFound
    /// A delta referenced a shape ID that is not a direct shape of the
    /// target cell.
    case unknownShapeID(UUID)
    /// A delta referenced a via ID that is not a direct via of the target
    /// cell.
    case unknownViaID(UUID)
    /// A delta added a shape whose ID already exists in the target cell.
    case duplicateShapeID(UUID)
    /// A delta added a via whose ID already exists in the target cell.
    case duplicateViaID(UUID)
    /// One element ID appeared in more than one of added/updated/removed
    /// within a single delta, making the intended end state ambiguous.
    case conflictingDeltaEntry(UUID)
    /// A direct element of the target cell shares its ID with an element
    /// contributed by an instantiated child cell, so ID-keyed component
    /// bookkeeping would be ambiguous.
    case hierarchyIdentifierCollision(UUID)
}
