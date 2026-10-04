import Foundation
import CircuiteFoundation
import LayoutCore
import LayoutTech
import MaskGeometry
import Testing
@testable import LayoutVerify

@Suite("Exact canonical rectilinear path capture", .timeLimit(.minutes(1)))
struct ConductorPathCaptureTests {
    private var metal: LayoutLayerID { .init(name: "M1", purpose: "drawing") }
    private func path(_ points: [LayoutPoint], width: Double = 1, cap: LayoutPathEndCap = .truncate) -> LayoutShape {
        .init(layer: metal, geometry: .path(.init(points: points, width: width, endCap: cap)))
    }
    private func document(_ shapes: [LayoutShape], scale: DatabaseUnitScale = .nanometerGrid) -> LayoutDocument {
        let cell = LayoutCell(name: "PATH", shapes: shapes)
        return .init(name: "path", units: .init(scale: scale), cells: [cell], topCellID: cell.id)
    }
    private func capture(_ shapes: [LayoutShape], limits: LayoutConductorCaptureLimits = .default) throws -> LayoutConductorSnapshot {
        try LayoutConnectivityExtractor().captureConductors(document: document(shapes), tech: .standard(),
            conductiveLayers: [metal], limits: limits)
    }
    private func covered(_ snapshot: LayoutConductorSnapshot, _ x: Double, _ y: Double) -> Bool {
        let scale = snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        return snapshot.footprints.contains {
            Double($0.band.minX) < x * scale && Double($0.band.maxX) > x * scale
                && Double($0.band.minY) < y * scale && Double($0.band.maxY) > y * scale
        }
    }
    private func areaSquareMicrometers(_ snapshot: LayoutConductorSnapshot) -> Double {
        let bands = snapshot.footprints.map(\.band)
        let xs = Set(bands.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set(bands.flatMap { [$0.minY, $0.maxY] }).sorted()
        var area: Double = 0
        for x in xs.indices.dropLast() { for y in ys.indices.dropLast() {
            if bands.contains(where: { $0.minX <= xs[x] && $0.maxX >= xs[x + 1] && $0.minY <= ys[y] && $0.maxY >= ys[y + 1] }) {
                area += Double(Int64(xs[x + 1]) - Int64(xs[x])) * Double(Int64(ys[y + 1]) - Int64(ys[y]))
            }
        } }
        let scale = snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        return area / scale / scale
    }

    @Test func flushAndExtendedStraightCapsHaveDifferentPhysicalCoverage() throws {
        let points = [LayoutPoint.zero, .init(x: 2, y: 0)]
        let flush = try capture([path(points)]), extended = try capture([path(points, cap: .extend)])
        #expect(areaSquareMicrometers(flush) == 2 && areaSquareMicrometers(extended) == 3)
        #expect(!covered(flush, -0.25, 0) && !covered(flush, 2.25, 0))
        #expect(covered(extended, -0.25, 0) && covered(extended, 2.25, 0))
        #expect(flush.hierarchy.units.scale.databaseUnitsPerMicrometer == 1_000)
        #expect(flush.coordinateUnits.scale.databaseUnitsPerMicrometer == 2_000)
    }

    @Test func rightAngleMiterFillsTheOuterCornerWithoutFillingTheConcaveVoid() throws {
        let shape = path([.zero, .init(x: 2, y: 0), .init(x: 2, y: 2)])
        let result = try capture([shape])
        #expect(areaSquareMicrometers(result) == 4)
        #expect(covered(result, 2.25, -0.25) && !covered(result, 1.25, 0.75))
        #expect(result.components.count == 1 && result.footprints.allSatisfy { $0.source == .shape(0) && $0.sourceID == shape.id })
    }

    @Test func reversedDirectionsAndCollinearVerticesKeepCapsAndJoinsExact() throws {
        let turned = try capture([path([.init(x: 2, y: 2), .init(x: 2, y: 0), .zero], cap: .extend)])
        #expect(areaSquareMicrometers(turned) == 5 && covered(turned, 2.25, -0.25))
        let straight = try capture([path([.zero, .init(x: 1, y: 0), .init(x: 4, y: 0)], cap: .extend)])
        #expect(areaSquareMicrometers(straight) == 5 && straight.components.count == 1)
    }

    @Test func oddDatabaseUnitWidthRetainsHalfGridBoundaries() throws {
        let result = try capture([path([.zero, .init(x: 0.003, y: 0)], width: 0.001, cap: .extend)])
        let band = try #require(result.footprints.first?.band)
        #expect(result.footprints.count == 1)
        #expect(band.minX == -1 && band.maxX == 7 && band.minY == -1 && band.maxY == 1)
        #expect(abs(areaSquareMicrometers(result) - 4e-6) < 1e-20)
        #expect(result.hierarchy.units == .defaultUnits && result.coordinateUnits.scale.databaseUnitsPerMicrometer == 2_000)
    }

    @Test func mixedGeometryUsesOneOwnedCoordinateScale() throws {
        let rectangle = LayoutShape(layer: metal, geometry: .rect(.init(origin: .init(x: 4, y: 1), size: .init(width: 1, height: 1))))
        let result = try capture([path([.zero, .init(x: 2, y: 0)]), rectangle])
        let rectangleBand = try #require(result.footprints.first { $0.sourceID == rectangle.id }?.band)
        #expect(rectangleBand.minX == 8_000 && rectangleBand.minY == 2_000)
        #expect(areaSquareMicrometers(result) == 3 && result.components.count == 2)
        let unchanged = try capture([rectangle])
        #expect(unchanged.coordinateUnits == unchanged.hierarchy.units)
    }

    @Test func capCoverageControlsActualMetalContact() throws {
        let other = LayoutShape(layer: metal, geometry: .rect(.init(origin: .init(x: 2.25, y: -0.1), size: .init(width: 0.1, height: 0.2))))
        let points = [LayoutPoint.zero, .init(x: 2, y: 0)]
        #expect(try capture([path(points), other]).components.count == 2)
        #expect(try capture([path(points, cap: .extend), other]).components.count == 1)
    }

    @Test func hierarchyScalesWidthAndRotatesTheCompleteStroke() throws {
        let child = LayoutCell(name: "CHILD", shapes: [path([.zero, .init(x: 2, y: 0)])])
        let root = LayoutCell(name: "ROOT", instances: [.init(cellID: child.id, name: "placed",
            transform: .init(translation: .init(x: 10, y: 0), rotation: .deg90, magnification: 2))])
        let doc = LayoutDocument(name: "hierarchy", cells: [root, child], topCellID: root.id)
        let result = try LayoutConnectivityExtractor().captureConductors(document: doc, tech: .standard(), conductiveLayers: [metal])
        #expect(areaSquareMicrometers(result) == 8)
        #expect(covered(result, 10.75, 3.75) && !covered(result, 10, 4.25))
        #expect(result.footprints.allSatisfy { $0.occurrenceIndex == 1 && $0.source == .shape(0) })
    }

    @Test func circularDiagonalZeroAndImmediateReversalPathsFailExplicitly() {
        for shape in [path([.zero, .init(x: 1, y: 0)], cap: .round), path([.zero, .init(x: 1, y: 1)]),
                      path([.zero, .zero]), path([.zero, .init(x: 1, y: 0), .zero])] {
            #expect(throws: LayoutConductorCaptureError.unsupportedGeometry(shape.id)) { try capture([shape]) }
        }
        let invalid = path([.zero, .init(x: 1, y: 0)], width: .infinity)
        #expect(throws: LayoutHierarchyCaptureError.invalidGeometry(invalid.id)) { try capture([invalid]) }
    }

    @Test func generatedOutlineWorkAndCoordinatesRemainBounded() throws {
        let shape = path([.zero, .init(x: 2, y: 0), .init(x: 2, y: 2)])
        #expect(throws: LayoutConductorCaptureError.decompositionFailed(.limitExceeded(.inputEntries))) {
            try capture([shape], limits: .init(decomposition: .init(maximumInputEntries: 10,
                maximumEdgeProbes: 100, maximumOutputBands: 100)))
        }
        let offGrid = path([.zero, .init(x: 1, y: 0)], width: 0.0003)
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(offGrid.id)) { try capture([offGrid]) }
        let outside = path([.zero, .init(x: 2_000_000, y: 0)])
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(outside.id)) { try capture([outside]) }
        let overflowScale = try DatabaseUnitScale(databaseUnitsPerMicrometer: .greatestFiniteMagnitude)
        #expect(throws: LayoutConductorCaptureError.invalidCoordinateUnits) {
            try LayoutConnectivityExtractor().captureConductors(document: document([shape], scale: overflowScale),
                tech: .standard(), conductiveLayers: [metal])
        }
    }

    @Test func cancellationStopsStrokeEmissionAndPublishesNoPartialSnapshot() throws {
        var emitted = 0, checks = 0
        let value = LayoutPath(points: (0..<10).map { .init(x: Double($0), y: 0) }, width: 1)
        #expect(throws: LayoutConductorCaptureError.cancelled) {
            try RectilinearPathFootprint.emit(value, sourceID: UUID(), isCancelled: { checks += 1; return checks == 3 }) { _ in emitted += 1 }
        }
        #expect(emitted == 2)
        let doc = document([path([.zero, .init(x: 2, y: 0), .init(x: 2, y: 2)])])
        var completeChecks = 0
        _ = try LayoutConnectivityExtractor().captureConductors(document: doc, tech: .standard(), conductiveLayers: [metal],
            isCancelled: { completeChecks += 1; return false })
        var lateChecks = 0, output: LayoutConductorSnapshot?
        #expect(throws: LayoutConductorCaptureError.cancelled) {
            output = try LayoutConnectivityExtractor().captureConductors(document: doc, tech: .standard(), conductiveLayers: [metal],
                isCancelled: { lateChecks += 1; return lateChecks == completeChecks - 1 })
        }
        #expect(output == nil)
    }
}
