import Foundation

/// A measurement ruler annotation on the canvas.
public struct LayoutRuler: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var start: LayoutPoint
    public var end: LayoutPoint

    public init(start: LayoutPoint, end: LayoutPoint) {
        self.id = UUID()
        self.start = start
        self.end = end
    }

    /// Distance in layout units.
    public var distance: Double {
        hypot(end.x - start.x, end.y - start.y)
    }

    /// Horizontal distance.
    public var dx: Double { abs(end.x - start.x) }

    /// Vertical distance.
    public var dy: Double { abs(end.y - start.y) }
}
