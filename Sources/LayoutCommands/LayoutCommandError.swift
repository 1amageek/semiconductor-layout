import Foundation

public enum LayoutCommandError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case missingDocumentIDForNewDocument
    case duplicateCellID(UUID)
    case duplicateNetID(UUID)
    case netNotFound(UUID)
    case duplicateShapeID(UUID)
    case duplicateLabelID(UUID)
    case duplicateViaID(UUID)
    case duplicateInstanceID(UUID)
    case cellNotFound(UUID)
    case shapeNotFound(UUID)
    case viaNotFound(UUID)
    case instanceNotFound(UUID)
    case invalidInstanceHierarchy(parentCellID: UUID, referencedCellID: UUID)
    case emptySelection
    case duplicateSelectionID(UUID)
    case deterministicIDCollision(kind: String, id: UUID)
    case invalidRectSize(width: Double, height: Double)
    case invalidShapeGeometry(kind: String)
    case missingRouteShapeID(String)
    case unsupportedResizeGeometry(UUID)
    case invalidResizeResult(shapeID: UUID, width: Double, height: Double)
    case unsupportedSplitGeometry(UUID)
    case invalidSplitCoordinate(shapeID: UUID, axis: SplitShapeAxis, coordinate: Double)
    case invalidRepairBudget(Int)
    case invalidConstraint(String)
    case constraintMemberNotFound(UUID)
    case invalidUUID(String)
    case invalidNumericValue(argument: String, value: String)
    case missingRequiredArgument(String)
    case missingValueAfter(String)
    case duplicateArgument(String)
    case unknownArgument(String)
    case invalidFormat(String)
    case conflictingArguments(String, String)
    case conflictingArtifactPath(String, String)
    case missingCommandMode
}

extension LayoutCommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported layout command schema version: \(version)"
        case .missingDocumentIDForNewDocument:
            return "documentID is required when inputDocumentPath is not provided"
        case .duplicateCellID(let id):
            return "Duplicate cell ID: \(id)"
        case .duplicateNetID(let id):
            return "Duplicate net ID: \(id)"
        case .netNotFound(let id):
            return "Net not found: \(id)"
        case .duplicateShapeID(let id):
            return "Duplicate shape ID: \(id)"
        case .duplicateLabelID(let id):
            return "Duplicate label ID: \(id)"
        case .duplicateViaID(let id):
            return "Duplicate via ID: \(id)"
        case .duplicateInstanceID(let id):
            return "Duplicate instance ID: \(id)"
        case .cellNotFound(let id):
            return "Cell not found: \(id)"
        case .shapeNotFound(let id):
            return "Shape not found: \(id)"
        case .viaNotFound(let id):
            return "Via not found: \(id)"
        case .instanceNotFound(let id):
            return "Instance not found: \(id)"
        case .invalidInstanceHierarchy(let parentCellID, let referencedCellID):
            return "Invalid instance hierarchy: cell \(parentCellID) cannot reference \(referencedCellID)"
        case .emptySelection:
            return "Selection must contain at least one shape or instance"
        case .duplicateSelectionID(let id):
            return "Duplicate selection ID: \(id)"
        case .deterministicIDCollision(let kind, let id):
            return "Deterministic \(kind) ID collides with existing layout content: \(id)"
        case .invalidRectSize(let width, let height):
            return "Invalid rect size: width=\(width), height=\(height)"
        case .invalidShapeGeometry(let kind):
            return "Invalid shape geometry: \(kind)"
        case .missingRouteShapeID(let segment):
            return "Missing route shape ID for segment: \(segment)"
        case .unsupportedResizeGeometry(let id):
            return "Resize only supports rectangle shapes: \(id)"
        case .invalidResizeResult(let shapeID, let width, let height):
            return "Invalid resize result for shape \(shapeID): width=\(width), height=\(height)"
        case .unsupportedSplitGeometry(let id):
            return "Split only supports rectangle shapes: \(id)"
        case .invalidSplitCoordinate(let shapeID, let axis, let coordinate):
            return "Invalid split coordinate for shape \(shapeID): axis=\(axis.rawValue), coordinate=\(coordinate)"
        case .invalidRepairBudget(let budget):
            return "Invalid repair budget: \(budget)"
        case .invalidConstraint(let reason):
            return "Invalid layout constraint: \(reason)"
        case .constraintMemberNotFound(let id):
            return "Constraint member not found: \(id)"
        case .invalidUUID(let rawValue):
            return "Invalid UUID: \(rawValue)"
        case .invalidNumericValue(let argument, let value):
            return "Invalid numeric value for \(argument): \(value)"
        case .missingRequiredArgument(let argument):
            return "Missing required argument: \(argument)"
        case .missingValueAfter(let argument):
            return "Missing value after \(argument)"
        case .duplicateArgument(let argument):
            return "Duplicate argument: \(argument)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .invalidFormat(let rawValue):
            return "Invalid layout file format: \(rawValue)"
        case .conflictingArguments(let lhs, let rhs):
            return "Conflicting arguments: \(lhs) and \(rhs)"
        case .conflictingArtifactPath(let roles, let path):
            return "Conflicting artifact path for \(roles): \(path)"
        case .missingCommandMode:
            return "Missing command mode: provide --request, --action-domain, --convert-document, --inspect-document, --validate-constraints, or --diagnose-connectivity"
        }
    }
}
