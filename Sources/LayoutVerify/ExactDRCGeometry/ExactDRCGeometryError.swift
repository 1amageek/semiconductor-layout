import Foundation

/// Exact admission failures retain source identity without publishing partial preparation.
enum ExactDRCGeometryError: Error, Equatable, Sendable {
    case invalidGridGeometry(sourceID: UUID?)
    case unsupportedGeometry(sourceID: UUID)
    case generatedPieceLimit
    case cancelled
}
