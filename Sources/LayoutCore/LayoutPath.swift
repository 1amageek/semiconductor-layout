import Foundation

public struct LayoutPath: Hashable, Sendable, Codable {
    public var points: [LayoutPoint]
    public var width: Double

    public init(points: [LayoutPoint], width: Double) {
        self.points = points
        self.width = width
    }

    public var isValid: Bool {
        points.count >= 2 && width > 0
    }
}
