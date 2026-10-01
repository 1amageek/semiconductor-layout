import Foundation
import LayoutCore
import Testing

@Suite("Canonical via geometry", .timeLimit(.minutes(1)))
struct LayoutViaGeometryTests {
    @Test func nestedAffineGeometryRoundTripsAndTransformsOffsets() throws {
        let via = LayoutVia(viaDefinitionID: "fixed", position: LayoutPoint(x: 2, y: 3),
                            geometryTransforms: [LayoutTransform(translation: LayoutPoint(x: 1, y: 0), rotation: .deg90)])
        let transforms = [LayoutTransform(translation: LayoutPoint(x: 10, y: 20), rotation: .deg90, magnification: 2, mirrorX: true),
                          LayoutTransform(translation: LayoutPoint(x: 4, y: 5), rotation: .deg270)]
        let transformed = via.transformed(by: transforms)
        let local = LayoutRect(origin: LayoutPoint(x: 1, y: 2), size: LayoutSize(width: 3, height: 4))
        var expected = via.geometry(forLocalRect: local)
        for transform in transforms.reversed() { expected = expected.transformed(by: transform) }
        #expect(transformed.geometry(forLocalRect: local) == expected)
        #expect(transformed.id == via.id)
        let encoded = try JSONEncoder().encode(transformed)
        #expect(try JSONDecoder().decode(LayoutVia.self, from: encoded) == transformed)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "geometryTransforms")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LayoutVia.self, from: missing) }
    }

    @Test(arguments: [90.0, 180.0, 270.0, -90.0, 450.0])
    func quarterTurnsRetainExactlyRectilinearEdges(rotation: Double) throws {
        let via = LayoutVia(viaDefinitionID: "fixed", position: .zero,
                            geometryTransforms: [LayoutTransform(rotationDegrees: rotation)])
        let geometry = via.geometry(forLocalRect: LayoutRect(origin: LayoutPoint(x: 1.9, y: 2.3),
                                                             size: LayoutSize(width: 0.8, height: 0.4)))
        guard case .polygon(let polygon) = geometry else { Issue.record("Expected transformed polygon"); return }
        for index in polygon.points.indices {
            let point = polygon.points[index]
            let next = polygon.points[(index + 1) % polygon.points.count]
            #expect(point.x == next.x || point.y == next.y)
        }
    }

    @Test func translationOnlyHierarchyRetainsIdentityLocalGeometry() {
        let via = LayoutVia(viaDefinitionID: "fixed", position: .zero)
        let transformed = via.transformed(by: [LayoutTransform(translation: LayoutPoint(x: 3, y: 4))])
        #expect(transformed.geometryTransforms.isEmpty)
        #expect(transformed.position == LayoutPoint(x: 3, y: 4))
    }

    @Test func nonfiniteSerializedViaPoseFailsDocumentValidation() {
        let via = LayoutVia(viaDefinitionID: "fixed", position: .zero,
                            geometryTransforms: [LayoutTransform(magnification: .infinity)])
        let cell = LayoutCell(name: "TOP", vias: [via])
        let result = LayoutDocumentValidator().validate(LayoutDocument(name: "invalid", cells: [cell], topCellID: cell.id))
        #expect(result.findings.contains { $0.code == "layout.via.transform-invalid" && $0.entityID == via.id.uuidString.lowercased() })
    }
}
