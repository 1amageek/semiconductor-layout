import Foundation
import LayoutCore

/// Pure geometry for handle-based editing: enumerating the handles a
/// geometry exposes and applying a drag offset to one of them.
///
/// All functions are deterministic transforms of the *origin* geometry —
/// an interactive session applies cumulative offsets to the geometry
/// captured when the gesture began, never to intermediate states, so a
/// drag is replayable and cancel restores exactly.
public enum LayoutHandleEditor {

    /// The vertex positions of a geometry in handle index order.
    public static func vertices(of geometry: LayoutGeometry) -> [LayoutPoint] {
        switch geometry {
        case .rect(let rect):
            return [
                LayoutPoint(x: rect.minX, y: rect.minY),
                LayoutPoint(x: rect.maxX, y: rect.minY),
                LayoutPoint(x: rect.maxX, y: rect.maxY),
                LayoutPoint(x: rect.minX, y: rect.maxY),
            ]
        case .polygon(let polygon):
            return polygon.points
        case .path(let path):
            return path.points
        }
    }

    /// The edges of a geometry in handle index order, as point pairs.
    /// Rect and polygon edges wrap around; path segments do not.
    public static func edges(of geometry: LayoutGeometry) -> [(start: LayoutPoint, end: LayoutPoint)] {
        let points = vertices(of: geometry)
        switch geometry {
        case .rect, .polygon:
            guard points.count >= 2 else { return [] }
            return points.indices.map { i in
                (points[i], points[(i + 1) % points.count])
            }
        case .path:
            guard points.count >= 2 else { return [] }
            return (0..<(points.count - 1)).map { i in
                (points[i], points[i + 1])
            }
        }
    }

    /// The origin geometry with `handle` displaced by `offset`.
    ///
    /// - A rect vertex moves its corner while the opposite corner stays
    ///   anchored; each dimension is clamped to `minimumSize` so the rect
    ///   can never invert or collapse.
    /// - A rect edge moves along its outward normal with the same clamp.
    /// - A polygon or path vertex moves freely by the offset.
    /// - A polygon or path edge moves both endpoints by the component of
    ///   the offset perpendicular to the edge, the classic stretch.
    ///
    /// Returns nil when the handle does not exist on this geometry.
    public static func apply(
        _ handle: LayoutShapeHandle,
        offset: LayoutPoint,
        to geometry: LayoutGeometry,
        minimumSize: Double
    ) -> LayoutGeometry? {
        switch geometry {
        case .rect(let rect):
            return applyToRect(handle, offset: offset, rect: rect, minimumSize: minimumSize)
        case .polygon(let polygon):
            guard let points = displacedPoints(
                handle,
                offset: offset,
                points: polygon.points,
                wraps: true
            ) else { return nil }
            return .polygon(LayoutPolygon(points: points))
        case .path(let path):
            guard let points = displacedPoints(
                handle,
                offset: offset,
                points: path.points,
                wraps: false
            ) else { return nil }
            return .path(LayoutPath(points: points, width: path.width, endCap: path.endCap))
        }
    }

    // MARK: - Rect

    private static func applyToRect(
        _ handle: LayoutShapeHandle,
        offset: LayoutPoint,
        rect: LayoutRect,
        minimumSize: Double
    ) -> LayoutGeometry? {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        let floorSize = max(minimumSize, 0)

        switch handle {
        case .vertex(let corner):
            switch corner {
            case 0: minX += offset.x; minY += offset.y
            case 1: maxX += offset.x; minY += offset.y
            case 2: maxX += offset.x; maxY += offset.y
            case 3: minX += offset.x; maxY += offset.y
            default: return nil
            }
        case .edge(let index):
            switch index {
            case 0: minY += offset.y
            case 1: maxX += offset.x
            case 2: maxY += offset.y
            case 3: minX += offset.x
            default: return nil
            }
        }

        // Clamp the moved sides against the anchored ones so the rect
        // keeps a positive size.
        switch handle {
        case .vertex(0), .vertex(3), .edge(3):
            minX = min(minX, rect.maxX - floorSize)
        case .vertex(1), .vertex(2), .edge(1):
            maxX = max(maxX, rect.minX + floorSize)
        default:
            break
        }
        switch handle {
        case .vertex(0), .vertex(1), .edge(0):
            minY = min(minY, rect.maxY - floorSize)
        case .vertex(2), .vertex(3), .edge(2):
            maxY = max(maxY, rect.minY + floorSize)
        default:
            break
        }
        switch handle {
        case .vertex(0): maxX = rect.maxX; maxY = rect.maxY
        case .vertex(1): minX = rect.minX; maxY = rect.maxY
        case .vertex(2): minX = rect.minX; minY = rect.minY
        case .vertex(3): maxX = rect.maxX; minY = rect.minY
        default: break
        }

        return .rect(LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        ))
    }

    // MARK: - Polygon / Path

    private static func displacedPoints(
        _ handle: LayoutShapeHandle,
        offset: LayoutPoint,
        points: [LayoutPoint],
        wraps: Bool
    ) -> [LayoutPoint]? {
        var result = points
        switch handle {
        case .vertex(let index):
            guard points.indices.contains(index) else { return nil }
            result[index] = points[index].translated(by: offset)
        case .edge(let index):
            let edgeCount = wraps ? points.count : points.count - 1
            guard index >= 0, index < edgeCount, points.count >= 2 else { return nil }
            let j = wraps ? (index + 1) % points.count : index + 1
            let start = points[index]
            let end = points[j]
            let move = perpendicularComponent(of: offset, alongEdgeFrom: start, to: end)
            result[index] = start.translated(by: move)
            result[j] = end.translated(by: move)
        }
        return result
    }

    /// The component of `offset` perpendicular to the edge direction —
    /// stretching slides an edge along its normal, never along itself.
    /// A degenerate edge keeps the full offset so it stays editable.
    private static func perpendicularComponent(
        of offset: LayoutPoint,
        alongEdgeFrom start: LayoutPoint,
        to end: LayoutPoint
    ) -> LayoutPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return offset }
        let along = (offset.x * dx + offset.y * dy) / lengthSquared
        return LayoutPoint(x: offset.x - along * dx, y: offset.y - along * dy)
    }
}
