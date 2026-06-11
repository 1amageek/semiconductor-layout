import Foundation

/// A grabbable feature of one shape's geometry for stretch and vertex
/// editing.
///
/// Indices follow the geometry's own point order. For a rect the corners
/// are numbered counterclockwise from the minimum corner — 0 = (minX,
/// minY), 1 = (maxX, minY), 2 = (maxX, maxY), 3 = (minX, maxY) — and edge
/// `i` runs from corner `i` to corner `(i + 1) % 4` (bottom, right, top,
/// left). For a polygon, edge `i` runs from vertex `i` to the next vertex
/// with wraparound; for a path, edge `i` is the segment from point `i` to
/// point `i + 1` without wraparound.
public enum LayoutShapeHandle: Hashable, Sendable {
    /// A vertex of the geometry: a rect corner, polygon vertex, or path
    /// point. Dragging it moves that point (for a rect, the two adjacent
    /// edges).
    case vertex(Int)
    /// An edge of the geometry. Dragging it stretches the edge along its
    /// normal, leaving the rest of the shape in place.
    case edge(Int)
}
