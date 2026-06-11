import Foundation
import Testing
import LayoutCore

/// Kind-preserving quarter-turn and mirror transforms on `LayoutGeometry`:
/// rects stay rects with swapped dimensions, paths keep width and end cap,
/// mirrored polygons keep their winding orientation, and CW/CCW about the
/// same pivot round-trips exactly.
@Suite("LayoutGeometry rotate/mirror", .timeLimit(.minutes(5)))
struct LayoutGeometryTransformTests {

    private let pivot = LayoutPoint(x: 1, y: 1)

    @Test func rotated90RectSwapsDimensionsAndRoundTrips() {
        let rect = LayoutGeometry.rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 4, height: 1)
        ))

        let turned = rect.rotated90(around: pivot, clockwise: true)
        #expect(turned == .rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: -2),
            size: LayoutSize(width: 1, height: 4)
        )), "a clockwise quarter turn stays a rect with width and height swapped")

        #expect(
            turned.rotated90(around: pivot, clockwise: false) == rect,
            "CCW about the same pivot must undo CW exactly"
        )
    }

    @Test func rotated90PathKeepsWidthAndEndCap() {
        let path = LayoutGeometry.path(LayoutPath(
            points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 2, y: 0)],
            width: 0.3,
            endCap: .round
        ))
        guard case .path(let turned) = path.rotated90(around: .zero, clockwise: false) else {
            Issue.record("rotating a path must stay a path")
            return
        }
        #expect(turned.points == [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 0, y: 2)])
        #expect(turned.width == 0.3)
        #expect(turned.endCap == .round)
    }

    @Test func mirroredRectKeepsSize() {
        let rect = LayoutGeometry.rect(LayoutRect(
            origin: LayoutPoint(x: 2, y: 0),
            size: LayoutSize(width: 3, height: 1)
        ))
        #expect(rect.mirrored(across: .vertical, through: pivot) == .rect(LayoutRect(
            origin: LayoutPoint(x: -3, y: 0),
            size: LayoutSize(width: 3, height: 1)
        )))
        #expect(rect.mirrored(across: .horizontal, through: pivot) == .rect(LayoutRect(
            origin: LayoutPoint(x: 2, y: 1),
            size: LayoutSize(width: 3, height: 1)
        )))
    }

    @Test func mirroredPolygonPreservesWindingOrientation() {
        // A counterclockwise L-shape (positive signed area).
        let polygon = LayoutPolygon(points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 2, y: 0),
            LayoutPoint(x: 2, y: 1),
            LayoutPoint(x: 1, y: 1),
            LayoutPoint(x: 1, y: 2),
            LayoutPoint(x: 0, y: 2),
        ])
        let original = signedArea(polygon)
        #expect(original > 0)

        let mirrored = LayoutGeometry.polygon(polygon)
            .mirrored(across: .vertical, through: pivot)
        guard case .polygon(let flipped) = mirrored else {
            Issue.record("mirroring a polygon must stay a polygon")
            return
        }
        #expect(
            signedArea(flipped) == original,
            "reflection flips winding; the reversed point order must flip it back"
        )
    }

    private func signedArea(_ polygon: LayoutPolygon) -> Double {
        let points = polygon.points
        var sum = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }
}
