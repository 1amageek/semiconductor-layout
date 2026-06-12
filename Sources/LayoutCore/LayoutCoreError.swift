import Foundation

public enum LayoutCoreError: Error, Sendable {
    case cellNotFound(UUID)
    case shapeNotFound(UUID)
    case viaNotFound(UUID)
    case labelNotFound(UUID)
    case pinNotFound(UUID)
    case instanceNotFound(UUID)
    case netNotFound(UUID)
    case invalidGeometry(String)
    case instanceCycle(parentCellID: UUID, childCellID: UUID)
}

extension LayoutCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cellNotFound(let id): return "Cell not found: \(id)"
        case .shapeNotFound(let id): return "Shape not found: \(id)"
        case .viaNotFound(let id): return "Via not found: \(id)"
        case .labelNotFound(let id): return "Label not found: \(id)"
        case .pinNotFound(let id): return "Pin not found: \(id)"
        case .instanceNotFound(let id): return "Instance not found: \(id)"
        case .netNotFound(let id): return "Net not found: \(id)"
        case .invalidGeometry(let msg): return "Invalid geometry: \(msg)"
        case .instanceCycle(let parent, let child):
            return "Placing cell \(child) into cell \(parent) would create an instance cycle"
        }
    }
}
