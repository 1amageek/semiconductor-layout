public enum LayoutCommandKind: String, Codable, Sendable, Equatable {
    case createCell
    case addNet
    case addRect
    case addShape
    case finishNet
    case translateShape
    case resizeShape
    case deleteShape
    case splitShape
    case addLabel
    case addVia
    case addInstance
    case moveInstance
    case rotateInstance
    case mirrorInstance
    case flattenInstance
    case makeCell
    case fixAllViolations
}
