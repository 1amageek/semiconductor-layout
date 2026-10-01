import Foundation

public enum LayoutDRCServiceError: Error, Equatable, Sendable {
    case targetCellNotFound(requestedCellID: UUID?, topCellID: UUID?)
    case hierarchyCaptureFailed(LayoutHierarchyCaptureError)
    case unsupportedDerivedGeometry(diagnostics: [LayoutDRCDiagnostic])
    case unsupportedExactGeometry(diagnostics: [LayoutDRCDiagnostic])
    case geometryOperationFailed(message: String)
}

extension LayoutDRCServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .targetCellNotFound(let requestedCellID, let topCellID):
            let requested = requestedCellID?.uuidString ?? "nil"
            let top = topCellID?.uuidString ?? "nil"
            return "DRC target cell not found. requestedCellID=\(requested), topCellID=\(top)"
        case .hierarchyCaptureFailed(let cause):
            return "DRC hierarchy capture failed: \(cause)"
        case .unsupportedDerivedGeometry(let diagnostics):
            return "Unsupported derived-layer geometry: \(diagnostics.map(\.message).joined(separator: " | "))"
        case .unsupportedExactGeometry(let diagnostics):
            return "Unsupported exact DRC geometry: \(diagnostics.map(\.message).joined(separator: " | "))"
        case .geometryOperationFailed(let message):
            return "Exact DRC geometry operation failed: \(message)"
        }
    }
}
