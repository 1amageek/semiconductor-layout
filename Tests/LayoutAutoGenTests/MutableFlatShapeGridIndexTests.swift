import Foundation
import Testing
import LayoutCore
@testable import LayoutVerify

@Suite("MutableFlatShapeGridIndex", .timeLimit(.minutes(1)))
struct MutableFlatShapeGridIndexTests {

    @Test func boundaryTouchingBoxesAreCandidates() {
        let left = Self.key(1)
        let right = Self.key(2)
        let index = MutableFlatShapeGridIndex(
            boundingBoxes: [
                (left, Self.rect(0, 0, 10, 10)),
                (right, Self.rect(10, 0, 10, 10)),
            ],
            cellSize: 10
        )

        let candidates = Set(index.neighbours(of: Self.rect(0, 0, 10, 10)))

        #expect(candidates.contains(left))
        #expect(
            candidates.contains(right),
            "closed-interval cell coverage must keep boundary-touching boxes in the candidate set"
        )
    }

    @Test func marginExpandsProbeBeforeCellLookup() {
        let near = Self.key(1)
        let index = MutableFlatShapeGridIndex(
            boundingBoxes: [(near, Self.rect(21, 0, 1, 1))],
            cellSize: 10
        )

        #expect(index.neighbours(of: Self.rect(18, 0, 1, 1)).isEmpty)
        #expect(index.neighbours(of: Self.rect(18, 0, 1, 1), margin: 2) == [near])
    }

    @Test func spanningBoxIsReturnedOnce() {
        let wide = Self.key(1)
        let index = MutableFlatShapeGridIndex(
            boundingBoxes: [(wide, Self.rect(0, 0, 25, 1))],
            cellSize: 10
        )

        #expect(index.neighbours(of: Self.rect(0, 0, 25, 1)) == [wide])
    }

    @Test func insertWithExistingKeyReplacesOldCells() {
        let key = Self.key(1)
        var index = MutableFlatShapeGridIndex(
            boundingBoxes: [(key, Self.rect(0, 0, 1, 1))],
            cellSize: 10
        )

        index.insert(key: key, box: Self.rect(100, 0, 1, 1))

        #expect(index.neighbours(of: Self.rect(0, 0, 1, 1)).isEmpty)
        #expect(index.neighbours(of: Self.rect(100, 0, 1, 1)) == [key])
    }

    @Test func removeDropsEveryCoveredCellAndUnknownRemoveIsNoOp() {
        let key = Self.key(1)
        var index = MutableFlatShapeGridIndex(
            boundingBoxes: [(key, Self.rect(0, 0, 25, 25))],
            cellSize: 10
        )

        index.remove(key: key)
        index.remove(key: Self.key(2))

        #expect(index.neighbours(of: Self.rect(0, 0, 25, 25)).isEmpty)
    }

    @Test func neighboursAreReturnedInCanonicalKeyOrder() {
        let high = Self.key(0x30)
        let low = Self.key(0x10)
        let child = FlatShapeKey.child(5)
        let index = MutableFlatShapeGridIndex(
            boundingBoxes: [
                (high, Self.rect(0, 0, 1, 1)),
                (low, Self.rect(0, 0, 1, 1)),
                (child, Self.rect(0, 0, 1, 1)),
            ],
            cellSize: 10
        )

        // FlatShapeKey order: child occurrences first, then top keys in
        // canonical UUID order.
        #expect(index.neighbours(of: Self.rect(0, 0, 1, 1)) == [child, low, high])
    }

    // MARK: - Cell-size heuristic

    @Test func cellSizeUsesTheSmallerDimensionSoWireLayersStaySelective() {
        // 500 long wires: sizing by the larger dimension would make ONE
        // cell span the whole layer and every probe return all 500 wires
        // (measured as a 327s session init before the fix).
        let wires = Array(repeating: Self.rect(0, 0, 500, 0.4), count: 500)
        let cellSize = ShapeGridIndex.defaultCellSize(for: wires)

        #expect(cellSize < 2.0, "wire-dominated layers must keep point probes selective")
        #expect(cellSize >= 500.0 / 256.0, "the longest box must not span more than ~256 cells")
    }

    @Test func cellSizeForCompactShapesMatchesTheirMeanDimension() {
        let pads = Array(repeating: Self.rect(0, 0, 0.4, 0.4), count: 100)
        // The mean accumulates float error, so compare with a tolerance.
        #expect(abs(ShapeGridIndex.defaultCellSize(for: pads) - 0.4) < 1e-12)
    }

    @Test func cellSizeBoundsInsertFanoutOfOneHugePlane() {
        var boxes = Array(repeating: Self.rect(0, 0, 0.4, 0.4), count: 1000)
        boxes.append(Self.rect(0, 0, 2000, 2000))
        let cellSize = ShapeGridIndex.defaultCellSize(for: boxes)

        #expect(cellSize >= 2000.0 / 256.0, "a huge plane must not explode into millions of cells")
    }

    private static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(x: x, y: y),
            size: LayoutSize(width: width, height: height)
        )
    }

    private static func key(_ lastByte: UInt8) -> FlatShapeKey {
        .top(UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, lastByte
        )))
    }
}
