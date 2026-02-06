import Foundation

public struct LayoutSegment: Hashable, Sendable, Codable {
    public var start: LayoutPoint
    public var end: LayoutPoint

    public init(start: LayoutPoint, end: LayoutPoint) {
        self.start = start
        self.end = end
    }
}
