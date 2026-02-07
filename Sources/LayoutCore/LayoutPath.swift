import Foundation

public struct LayoutPath: Hashable, Sendable, Codable {
    public var points: [LayoutPoint]
    public var width: Double
    public var endCap: LayoutPathEndCap

    public init(points: [LayoutPoint], width: Double, endCap: LayoutPathEndCap = .extend) {
        self.points = points
        self.width = width
        self.endCap = endCap
    }

    public var isValid: Bool {
        points.count >= 2 && width > 0
    }
}
