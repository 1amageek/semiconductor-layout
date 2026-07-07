import Foundation

public enum LayoutViolationKind: String, Sendable, Codable, CaseIterable {
    case minWidth
    case minSpacing
    case minArea
    case notch
    case rectOnly
    case angle
    case minEnclosedArea
    case enclosure
    case minimumCut
    case exactOverlap
    case forbiddenLayer
    case density
    case `extension`
    case ruleCoverage
    case overlapShort
    case disconnectedOpen
    case antenna
}
