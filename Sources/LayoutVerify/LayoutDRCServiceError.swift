import Foundation

public enum LayoutDRCServiceError: Error, Equatable, Sendable {
    case targetCellNotFound(requestedCellID: UUID?, topCellID: UUID?)
    case invalidHierarchy(messages: [String])
    case unsupportedDerivedGeometry(messages: [String])
    case unsupportedExactGeometry(messages: [String])
    case geometryOperationFailed(message: String)
}

extension LayoutDRCServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .targetCellNotFound(let requestedCellID, let topCellID):
            let requested = requestedCellID?.uuidString ?? "nil"
            let top = topCellID?.uuidString ?? "nil"
            return "DRC target cell not found. requestedCellID=\(requested), topCellID=\(top)"
        case .invalidHierarchy(let messages):
            return "Invalid DRC hierarchy: \(messages.joined(separator: " | "))"
        case .unsupportedDerivedGeometry(let messages):
            return "Unsupported derived-layer geometry: \(messages.joined(separator: " | "))"
        case .unsupportedExactGeometry(let messages):
            return "Unsupported exact DRC geometry: \(messages.joined(separator: " | "))"
        case .geometryOperationFailed(let message):
            return "Exact DRC geometry operation failed: \(message)"
        }
    }
}
