import Foundation
import Testing
import LayoutCore

/// Contract of `LayoutPolygon.subtract(cut:)` when the cut severs the
/// polygon: the result must be one simple polygon per remainder piece,
/// never a single self-intersecting boundary that visually bridges the
/// gap the cut created.
@Suite("LayoutPolygon subtract")
struct LayoutPolygonSubtractTests {

    private func rectPolygon(x: Double, y: Double, width: Double, height: Double) -> LayoutPolygon {
        LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: width, height: height)
        ).toPolygon()
    }

    @Test func severingCutProducesTwoDisjointPieces() {
        let polygon = rectPolygon(x: 0, y: 0, width: 1.0, height: 0.4)
        let cut = LayoutRect(
            origin: LayoutPoint(x: 0.4, y: -0.1),
            size: LayoutSize(width: 0.2, height: 0.6)
        )

        let remainders = polygon.subtract(cut: cut)

        #expect(remainders.count == 2)
        let areas = remainders.map { abs($0.signedArea) }.sorted()
        #expect(areas.allSatisfy { abs($0 - 0.16) < 1e-9 })
        let boxes = remainders.map { LayoutGeometryAnalysis.boundingBox(for: $0) }
        let sorted = boxes.sorted { $0.minX < $1.minX }
        #expect(abs(sorted[0].minX - 0.0) < 1e-9 && abs(sorted[0].maxX - 0.4) < 1e-9)
        #expect(abs(sorted[1].minX - 0.6) < 1e-9 && abs(sorted[1].maxX - 1.0) < 1e-9)
    }

    @Test func severingCutOfLShapeProducesThreePieces() {
        // A U-shaped polygon cut through its base leaves three pieces:
        // the two arms and the stub of the base on each side merge into
        // two L pieces plus nothing else; cutting the FULL base apart
        // separates the arms entirely.
        let u = LayoutPolygon(points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 3, y: 0),
            LayoutPoint(x: 3, y: 2),
            LayoutPoint(x: 2, y: 2),
            LayoutPoint(x: 2, y: 1),
            LayoutPoint(x: 1, y: 1),
            LayoutPoint(x: 1, y: 2),
            LayoutPoint(x: 0, y: 2),
        ])
        // Sever vertically through the base under the U's opening.
        let cut = LayoutRect(
            origin: LayoutPoint(x: 1.4, y: -0.5),
            size: LayoutSize(width: 0.2, height: 2)
        )

        let remainders = u.subtract(cut: cut)

        #expect(remainders.count == 2)
        let totalArea = remainders.reduce(0.0) { $0 + abs($1.signedArea) }
        // Original area 3*2 - 1*1 = 5; cut removes 0.2 * 1 = 0.2.
        #expect(abs(totalArea - 4.8) < 1e-9)
    }

    @Test func cornerCutKeepsSinglePiece() {
        let polygon = rectPolygon(x: 0, y: 0, width: 1, height: 1)
        let cut = LayoutRect(
            origin: LayoutPoint(x: 0.8, y: 0.8),
            size: LayoutSize(width: 0.4, height: 0.4)
        )

        let remainders = polygon.subtract(cut: cut)

        #expect(remainders.count == 1)
        #expect(abs(abs(remainders[0].signedArea) - 0.96) < 1e-9)
    }
}
