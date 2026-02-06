import Foundation

public struct LayoutPolygon: Hashable, Sendable, Codable {
    public var points: [LayoutPoint]

    public init(points: [LayoutPoint]) {
        self.points = points
    }

    public var isValid: Bool {
        points.count >= 3
    }
}
