import Foundation

/// Typed failures for geometry deltas that cannot be applied safely.
public enum LayoutEditDeltaValidationError: Error, Equatable, Sendable {
    case unknownShapeID(UUID)
    case unknownViaID(UUID)
    case duplicateShapeID(UUID)
    case duplicateViaID(UUID)
    case conflictingDeltaEntry(UUID)
}

extension LayoutEditDeltaValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownShapeID(let id):
            return "Delta referenced an unknown shape ID: \(id)"
        case .unknownViaID(let id):
            return "Delta referenced an unknown via ID: \(id)"
        case .duplicateShapeID(let id):
            return "Delta added a shape ID that already exists: \(id)"
        case .duplicateViaID(let id):
            return "Delta added a via ID that already exists: \(id)"
        case .conflictingDeltaEntry(let id):
            return "Delta contains conflicting operations for element ID: \(id)"
        }
    }
}
