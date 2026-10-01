import Foundation

public enum LayoutHierarchyCaptureError: Error, Equatable, Sendable {
    public enum Resource: String, Equatable, Sendable {
        case occurrences, objects, geometryPoints, depth
    }

    case invalidLimits
    case targetCellNotFound(UUID?)
    case duplicateCellID(UUID)
    case duplicateObjectID(cellID: UUID, objectID: UUID)
    case missingChildCell(UUID)
    case hierarchyCycle(UUID)
    case invalidRepetition(UUID)
    case repetitionOverflow(UUID)
    case invalidGeometry(UUID)
    case invalidTransform(UUID)
    case limitExceeded(Resource)
    case cancelled
}
