import Foundation

public enum LayoutViolationKind: String, Sendable, Codable {
    case minWidth
    case minSpacing
    case minArea
    case notch
    case minEnclosedArea
    case enclosure
    case density
    case ruleCoverage
    case overlapShort
    case disconnectedOpen
    case antenna
}
