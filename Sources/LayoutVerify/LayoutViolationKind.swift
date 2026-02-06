import Foundation

public enum LayoutViolationKind: String, Sendable, Codable {
    case minWidth
    case minSpacing
    case minArea
    case enclosure
    case density
    case overlapShort
    case disconnectedOpen
    case antenna
}
