import Foundation

public enum LayoutDRCServiceError: Error, Equatable, Sendable {
    case targetCellNotFound(requestedCellID: UUID?, topCellID: UUID?)
}

extension LayoutDRCServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .targetCellNotFound(let requestedCellID, let topCellID):
            let requested = requestedCellID?.uuidString ?? "nil"
            let top = topCellID?.uuidString ?? "nil"
            return "DRC target cell not found. requestedCellID=\(requested), topCellID=\(top)"
        }
    }
}
