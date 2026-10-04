import Foundation
import Testing
@testable import LayoutCore

@Suite("Canonical signed path geometry", .timeLimit(.minutes(1)))
struct LayoutPathGeometryTests {
    @Test func customCapsOwnPhysicalBoundsPickingAndArea() throws {
        let path = LayoutPath(points: [.zero, .init(x: 2, y: 0)], width: 1,
                              endCap: .custom(begin: 3, end: -0.5))
        let geometry = LayoutGeometry.path(path)
        let box = LayoutGeometryAnalysis.boundingBox(for: geometry)
        #expect(box.minX == -3 && box.maxX == 1.5 && box.minY == -0.5 && box.maxY == 0.5)
        #expect(LayoutGeometryAnalysis.area(of: geometry) == 4.5)
        #expect(LayoutGeometryAnalysis.contains(.init(x: -2, y: 0), in: geometry))
        #expect(!LayoutGeometryAnalysis.contains(.init(x: 1.75, y: 0), in: geometry))
        let other = LayoutGeometry.rect(.init(origin: .init(x: -2.1, y: -0.1), size: .init(width: 0.2, height: 0.2)))
        #expect(LayoutGeometryAnalysis.intersects(geometry, other))
        let reversed = LayoutPath(points: Array(path.points.reversed()), width: 1,
                                 endCap: .custom(begin: -0.5, end: 3))
        #expect(LayoutGeometryAnalysis.boundingBox(for: reversed) == box)
    }

    @Test func rectangleDistanceUsesActualExtendedAndRetractedCaps() {
        let wire = LayoutGeometry.path(.init(points: [.zero, .init(x: 2, y: 0)], width: 1,
                                            endCap: .custom(begin: 3, end: -0.5)))
        let contained = LayoutGeometry.rect(.init(origin: .init(x: -2, y: -0.1), size: .init(width: 0.2, height: 0.2)))
        let separated = LayoutGeometry.rect(.init(origin: .init(x: 2, y: -0.1), size: .init(width: 0.2, height: 0.2)))
        #expect(LayoutGeometryAnalysis.minimumDistance(between: wire, and: contained) == 0)
        #expect(LayoutGeometryAnalysis.minimumDistance(between: wire, and: separated) == 0.5)
        #expect(LayoutGeometryAnalysis.minimumDistance(between: contained, and: wire) == 0)
    }

    @Test func magnificationAndSerializationPreserveSeparateEndpointDistances() throws {
        let value = LayoutGeometry.path(.init(points: [.zero, .init(x: 2, y: 0)], width: 1,
                                               endCap: .custom(begin: 3, end: -0.5)))
        let changed = value.transformed(by: .init(translation: .init(x: 10, y: 0), rotation: .deg90, magnification: 2, mirrorX: true))
        guard case .path(let path) = changed else { Issue.record("Expected path"); return }
        #expect(path.width == 2 && path.endCap == .custom(begin: 6, end: -1))
        #expect(try JSONDecoder().decode(LayoutGeometry.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(LayoutGeometryAnalysis.boundingBox(for: changed).minY == -3 && LayoutGeometryAnalysis.boundingBox(for: changed).maxY == 6)
    }

    @Test func offsetLineIntersectionPreservesTheRightAngleMiter() throws {
        let path = LayoutPath(points: [.zero, .init(x: 2, y: 0), .init(x: 2, y: 2)], width: 1,
                              endCap: .custom(begin: 0.25, end: 1))
        let polygon = try path.flatOutline()
        #expect(polygon.points.contains(.init(x: 2.5, y: -0.5)))
        #expect(polygon.points.contains(.init(x: 1.5, y: 0.5)))
        #expect(LayoutGeometryAnalysis.area(of: polygon) == 5.25)
        #expect(LayoutGeometryAnalysis.boundingBox(for: path).maxY == 3)
    }

    @Test func invalidValuesRetractionsAndUnsupportedCurvesFail() {
        let points = [LayoutPoint.zero, .init(x: 2, y: 0)]
        let invalid = LayoutGeometry.path(.init(points: points, width: 1, endCap: .custom(begin: -2, end: 10)))
        #expect(LayoutGeometryAnalysis.boundingBox(for: invalid).minX.isNaN)
        #expect(LayoutGeometryAnalysis.area(of: invalid).isNaN)
        #expect(LayoutGeometryAnalysis.minimumDistance(between: invalid, and: invalid).isNaN)
        #expect(throws: LayoutPathGeometryError.invalidValue) {
            try LayoutPath(points: points, width: 1, endCap: .custom(begin: .infinity, end: 0)).flatOutline()
        }
        #expect(throws: LayoutPathGeometryError.invalidRetraction) {
            try LayoutPath(points: points, width: 1, endCap: .custom(begin: -2, end: 10)).flatOutline()
        }
        #expect(throws: LayoutPathGeometryError.invalidRetraction) {
            try LayoutPath(points: points, width: 1, endCap: .custom(begin: -1.5, end: -1)).flatOutline()
        }
        #expect(throws: LayoutPathGeometryError.unsupportedCircularOutline) {
            try LayoutPath(points: points, width: 1, endCap: .round).flatOutline()
        }
        #expect(throws: LayoutPathGeometryError.immediateReversal) {
            try LayoutPath(points: [.zero, .init(x: 2, y: 0), .zero], width: 1).flatOutline()
        }
    }
}
