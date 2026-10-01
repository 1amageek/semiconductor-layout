import Foundation
import Testing
import LayoutCore
import LayoutTech
@testable import LayoutVerify

@Suite("Hierarchical via geometry", .timeLimit(.minutes(1)))
struct HierarchicalViaGeometryTests {
    private let lower = LayoutLayerID(name: "M1", purpose: "drawing")
    private let upper = LayoutLayerID(name: "M2", purpose: "drawing")
    private let cut = LayoutLayerID(name: "V1", purpose: "cut")

    @Test(arguments: [90.0, 180.0, 270.0])
    func transformedChildViaContactsItsOwnMetal(rotation: Double) throws {
        let fixture = makeFixture(rotation: rotation)
        let extractor = LayoutConnectivityExtractor()
        let result = try extractor.extract(document: fixture.document, tech: fixture.technology)
        #expect(result.nets.count == 1)
        #expect(result.nets[0].shapeIDs.count == 2)
        #expect(result.nets[0].viaIDs.count == 1)
        #expect(result.opens.isEmpty)
        #expect(result.shorts.isEmpty)
        let live = try LiveConnectivitySession(document: fixture.document, tech: fixture.technology)
        #expect(live.currentAnalysis == result)
    }

    @Test func quarterTurnTransformsEveryLayerAndPinExtent() throws {
        let fixture = makeFixture(rotation: 90)
        let flat = try LayoutConnectivityExtractor().flattenedConductors(document: fixture.document, tech: fixture.technology)
        let via = try #require(flat.vias.first)
        let service = LayoutDRCService()
        let cutRects = service.viaCutRects(for: via, tech: fixture.technology)
        #expect(cutRects.count == 1)
        let rect = try #require(cutRects.first)
        #expect(abs(rect.minX - 5.8) < 1e-9)
        #expect(abs(rect.maxX - 6.2) < 1e-9)
        #expect(abs(rect.minY - 12.8) < 1e-9)
        #expect(abs(rect.maxY - 14.0) < 1e-9)
        for layer in [lower, upper] {
            let metal = try #require(service.viaLayerRects(for: via, layer: layer, tech: fixture.technology).first)
            #expect(abs(metal.minX - 5.6) < 1e-9)
            #expect(abs(metal.maxX - 6.4) < 1e-9)
            #expect(abs(metal.minY - 12.6) < 1e-9)
            #expect(abs(metal.maxY - 14.2) < 1e-9)
        }
        let pin = try #require(flat.pins.first)
        #expect(abs(pin.size.width - 1) < 1e-9)
        #expect(abs(pin.size.height - 4) < 1e-9)
    }

    @Test func repeatedChildViasPreserveDistinctTransformedFootprints() throws {
        var fixture = makeFixture(rotation: 90)
        let rootIndex = try #require(fixture.document.cells.firstIndex { $0.id == fixture.document.topCellID })
        let original = try #require(fixture.document.cells[rootIndex].instances.first)
        fixture.document.cells[rootIndex].instances.append(LayoutInstance(
            cellID: original.cellID, name: "second",
            transform: LayoutTransform(translation: LayoutPoint(x: 30, y: 20), rotation: .deg90,
                                       magnification: 2, mirrorX: true)
        ))
        let flat = try LayoutConnectivityExtractor().flattenedConductors(document: fixture.document, tech: fixture.technology)
        #expect(flat.vias.count == 2)
        #expect(flat.vias[0].id == flat.vias[1].id)
        let service = LayoutDRCService()
        let first = try #require(service.viaCutRects(for: flat.vias[0], tech: fixture.technology).first)
        let second = try #require(service.viaCutRects(for: flat.vias[1], tech: fixture.technology).first)
        #expect(abs(first.minX - 5.8) < 1e-9)
        #expect(abs(second.minX - 25.8) < 1e-9)
        let analysis = try LayoutConnectivityExtractor().extract(document: fixture.document, tech: fixture.technology)
        #expect(analysis.nets.count == 2)
        #expect(analysis.nets.allSatisfy { $0.viaIDs.count == 1 && $0.shapeIDs.count == 2 })
    }

    @Test func exactOnlyRejectsNonrectilinearViaWithoutShapes() throws {
        var fixture = makeFixture(rotation: 45)
        let childIndex = try #require(fixture.document.cells.firstIndex { $0.name == "CHILD" })
        fixture.document.cells[childIndex].shapes = []
        fixture.document.cells[childIndex].pins = []
        let result = LayoutDRCService().run(document: fixture.document, tech: fixture.technology, geometryMode: .exactOnly)
        #expect(result.diagnostics.contains { $0.code == "drc.unsupported_exact_geometry" && $0.message.contains("Via") })
        #expect(throws: LayoutDRCServiceError.self) {
            try LayoutDRCService().runChecked(document: fixture.document, tech: fixture.technology, geometryMode: .exactOnly)
        }
    }

    @Test func exactOnlyAcceptsQuarterTurnViaWithoutShapes() throws {
        var fixture = makeFixture(rotation: 90)
        let childIndex = try #require(fixture.document.cells.firstIndex { $0.name == "CHILD" })
        fixture.document.cells[childIndex].shapes = []
        fixture.document.cells[childIndex].pins = []
        let result = try LayoutDRCService().runChecked(document: fixture.document, tech: fixture.technology, geometryMode: .exactOnly)
        #expect(result.diagnostics.isEmpty)
    }

    private func makeFixture(rotation: Double) -> (document: LayoutDocument, technology: LayoutTechDatabase) {
        let metal = LayoutRect(origin: LayoutPoint(x: 1.9, y: -0.2), size: LayoutSize(width: 0.8, height: 0.4))
        let cutRect = LayoutRect(origin: LayoutPoint(x: 2, y: -0.1), size: LayoutSize(width: 0.6, height: 0.2))
        let technology = LayoutTechDatabase(
            layers: [lower, upper, cut].enumerated().map { index, layer in
                LayoutLayerDefinition(id: layer, displayName: layer.name, gdsLayer: index + 1, gdsDatatype: 0,
                                      color: LayoutColor(red: 0.5, green: 0.5, blue: 0.5))
            },
            vias: [LayoutViaDefinition(id: "fixed", cutLayer: cut, topLayer: upper, bottomLayer: lower,
                    cutSize: cutRect.size, enclosure: LayoutViaEnclosure(top: 0.1, bottom: 0.1), cutSpacing: 1,
                    layerGeometries: [LayoutViaLayerGeometry(layer: lower, rects: [metal]),
                                     LayoutViaLayerGeometry(layer: cut, rects: [cutRect]),
                                     LayoutViaLayerGeometry(layer: upper, rects: [metal])])],
            layerRules: []
        )
        let viaPosition = LayoutPoint(x: 1, y: 2)
        let net = UUID()
        let shapes = [lower, upper].map { layer in
            LayoutShape(layer: layer, netID: net,
                        geometry: .rect(LayoutRect(origin: LayoutPoint(x: 2.9, y: 1.8), size: metal.size)))
        }
        let child = LayoutCell(name: "CHILD", shapes: shapes,
                     vias: [LayoutVia(viaDefinitionID: "fixed", position: viaPosition, netID: net)],
                     pins: [LayoutPin(name: "P", position: LayoutPoint(x: 3.3, y: 2),
                                      size: LayoutSize(width: 2, height: 0.5), layer: lower, netID: net)])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "first",
                     transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 20), rotationDegrees: rotation,
                                                magnification: 2, mirrorX: true))])
        return (LayoutDocument(name: "hierarchical-via", cells: [top, child], topCellID: top.id), technology)
    }
}
