import Foundation
import Testing
import LayoutCore
import LayoutEditor

/// Pure-geometry contract of `LayoutHandleEditor`: handle enumeration
/// follows the documented index order, every transform is computed from
/// the origin geometry (replayable), rects clamp instead of inverting,
/// and edge stretches move along the edge normal only.
@Suite("LayoutHandleEditor", .timeLimit(.minutes(5)))
struct LayoutHandleEditorTests {

    private let rect = LayoutGeometry.rect(LayoutRect(
        origin: LayoutPoint(x: 1, y: 2),
        size: LayoutSize(width: 4, height: 3)
    ))

    private let square = LayoutGeometry.polygon(LayoutPolygon(points: [
        LayoutPoint(x: 0, y: 0),
        LayoutPoint(x: 2, y: 0),
        LayoutPoint(x: 2, y: 2),
        LayoutPoint(x: 0, y: 2),
    ]))

    private let path = LayoutGeometry.path(LayoutPath(
        points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 3, y: 0),
            LayoutPoint(x: 3, y: 2),
        ],
        width: 0.2,
        endCap: .extend
    ))

    // MARK: - Enumeration

    @Test func rectHandlesFollowCounterclockwiseCornerOrder() {
        let vertices = LayoutHandleEditor.vertices(of: rect)
        #expect(vertices == [
            LayoutPoint(x: 1, y: 2),
            LayoutPoint(x: 5, y: 2),
            LayoutPoint(x: 5, y: 5),
            LayoutPoint(x: 1, y: 5),
        ])

        let edges = LayoutHandleEditor.edges(of: rect)
        #expect(edges.count == 4)
        #expect(edges[0].start == vertices[0] && edges[0].end == vertices[1])
        #expect(edges[3].start == vertices[3] && edges[3].end == vertices[0], "rect edges wrap")
    }

    @Test func pathEdgesDoNotWrap() {
        #expect(LayoutHandleEditor.vertices(of: path).count == 3)
        let edges = LayoutHandleEditor.edges(of: path)
        #expect(edges.count == 2, "a 3-point path has 2 segments, no wraparound")

        let polygonEdges = LayoutHandleEditor.edges(of: square)
        #expect(polygonEdges.count == 4, "a 4-point polygon has 4 edges with wraparound")
    }

    // MARK: - Rect transforms

    @Test func rectVertexDragAnchorsOppositeCorner() throws {
        let moved = try #require(LayoutHandleEditor.apply(
            .vertex(0),
            offset: LayoutPoint(x: 0.5, y: 1.0),
            to: rect,
            minimumSize: 0.1
        ))
        #expect(moved == .rect(LayoutRect(
            origin: LayoutPoint(x: 1.5, y: 3.0),
            size: LayoutSize(width: 3.5, height: 2.0)
        )), "corner 0 moves; the opposite corner (5,5) stays anchored")
    }

    @Test func rectVertexDragClampsAtMinimumSizeInsteadOfInverting() throws {
        // Integer floor size keeps the clamped arithmetic exact in floats.
        let collapsed = try #require(LayoutHandleEditor.apply(
            .vertex(0),
            offset: LayoutPoint(x: 100, y: 100),
            to: rect,
            minimumSize: 1.0
        ))
        #expect(collapsed == .rect(LayoutRect(
            origin: LayoutPoint(x: 4, y: 4),
            size: LayoutSize(width: 1, height: 1)
        )), "a drag past the opposite corner clamps to the floor size, never inverts")
    }

    @Test func rectEdgeDragMovesOneSideOnly() throws {
        let stretched = try #require(LayoutHandleEditor.apply(
            .edge(1),
            offset: LayoutPoint(x: 2.0, y: 50.0),
            to: rect,
            minimumSize: 0.1
        ))
        #expect(stretched == .rect(LayoutRect(
            origin: LayoutPoint(x: 1, y: 2),
            size: LayoutSize(width: 6, height: 3)
        )), "the right edge follows x only; the y component of the offset is ignored")
    }

    // MARK: - Polygon / path transforms

    @Test func polygonVertexDragMovesOnePoint() throws {
        let moved = try #require(LayoutHandleEditor.apply(
            .vertex(2),
            offset: LayoutPoint(x: 0.5, y: -0.25),
            to: square,
            minimumSize: 0.1
        ))
        guard case .polygon(let polygon) = moved else {
            Issue.record("polygon vertex drag must stay a polygon")
            return
        }
        #expect(polygon.points[2] == LayoutPoint(x: 2.5, y: 1.75))
        #expect(polygon.points[0] == LayoutPoint(x: 0, y: 0), "other vertices stay put")
    }

    @Test func polygonEdgeDragMovesAlongTheNormalOnly() throws {
        // Edge 0 runs (0,0)→(2,0); only the offset's y component is
        // perpendicular to it.
        let stretched = try #require(LayoutHandleEditor.apply(
            .edge(0),
            offset: LayoutPoint(x: 1.5, y: -0.5),
            to: square,
            minimumSize: 0.1
        ))
        guard case .polygon(let polygon) = stretched else {
            Issue.record("polygon edge drag must stay a polygon")
            return
        }
        #expect(polygon.points[0] == LayoutPoint(x: 0, y: -0.5))
        #expect(polygon.points[1] == LayoutPoint(x: 2, y: -0.5))
        #expect(polygon.points[2] == LayoutPoint(x: 2, y: 2), "non-edge vertices stay put")

        // The wrapping edge 3 runs (0,2)→(0,0); only x is perpendicular.
        let wrapped = try #require(LayoutHandleEditor.apply(
            .edge(3),
            offset: LayoutPoint(x: 0.7, y: 0.3),
            to: square,
            minimumSize: 0.1
        ))
        guard case .polygon(let wrappedPolygon) = wrapped else {
            Issue.record("polygon edge drag must stay a polygon")
            return
        }
        #expect(wrappedPolygon.points[3] == LayoutPoint(x: 0.7, y: 2))
        #expect(wrappedPolygon.points[0] == LayoutPoint(x: 0.7, y: 0))
    }

    @Test func pathEditsPreserveWidthAndEndCap() throws {
        let moved = try #require(LayoutHandleEditor.apply(
            .vertex(1),
            offset: LayoutPoint(x: 0, y: 1),
            to: path,
            minimumSize: 0.1
        ))
        guard case .path(let layoutPath) = moved else {
            Issue.record("path vertex drag must stay a path")
            return
        }
        #expect(layoutPath.points[1] == LayoutPoint(x: 3, y: 1))
        #expect(layoutPath.width == 0.2)
        #expect(layoutPath.endCap == .extend)
    }

    @Test func degenerateEdgeKeepsTheFullOffset() throws {
        let degenerate = LayoutGeometry.path(LayoutPath(
            points: [LayoutPoint(x: 1, y: 1), LayoutPoint(x: 1, y: 1)],
            width: 0.2,
            endCap: .truncate
        ))
        let moved = try #require(LayoutHandleEditor.apply(
            .edge(0),
            offset: LayoutPoint(x: 0.4, y: -0.3),
            to: degenerate,
            minimumSize: 0.1
        ))
        guard case .path(let layoutPath) = moved else {
            Issue.record("degenerate path edge drag must stay a path")
            return
        }
        #expect(layoutPath.points[0] == LayoutPoint(x: 1.4, y: 0.7))
        #expect(layoutPath.points[1] == LayoutPoint(x: 1.4, y: 0.7))
    }

    // MARK: - Invalid handles

    @Test func nonexistentHandlesReturnNil() {
        #expect(LayoutHandleEditor.apply(
            .vertex(4), offset: .zero, to: rect, minimumSize: 0.1
        ) == nil)
        #expect(LayoutHandleEditor.apply(
            .edge(4), offset: .zero, to: rect, minimumSize: 0.1
        ) == nil)
        #expect(LayoutHandleEditor.apply(
            .vertex(9), offset: .zero, to: square, minimumSize: 0.1
        ) == nil)
        #expect(LayoutHandleEditor.apply(
            .edge(2), offset: .zero, to: path, minimumSize: 0.1
        ) == nil, "a 3-point path has segments 0 and 1 only")
    }
}
