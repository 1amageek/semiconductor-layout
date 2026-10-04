import Foundation
import Testing
import DEF
import LayoutCore
import LayoutIR
import LayoutTech
import LayoutVerify
@testable import LayoutIO

@Suite("Typed DEF via export", .timeLimit(.minutes(1)))
struct TypedViaExportTests {
    private let fixture = TypedViaPlacementIntegrationTests()

    private func outputURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typed-via-\(UUID().uuidString).def")
    }

    private func compareNative(_ before: LayoutDocument, _ after: LayoutDocument,
                               tech: LayoutTechDatabase) throws {
        let layers = Set(tech.layers.filter { $0.id.purpose == "drawing" }.map(\.id))
        let original = try LayoutConnectivityExtractor().captureConductors(document: before,
            tech: tech, conductiveLayers: layers)
        let restored = try LayoutConnectivityExtractor().captureConductors(document: after,
            tech: tech, conductiveLayers: layers)
        #expect(original.coordinateUnits == restored.coordinateUnits)
        #expect(original.footprints.map(\.band) == restored.footprints.map(\.band))
        #expect(original.footprints.map(\.layer) == restored.footprints.map(\.layer))
        #expect(original.footprints.map(\.isCut) == restored.footprints.map(\.isCut))
        #expect(original.contacts == restored.contacts)
        #expect(original.components.map { $0.footprintIndices } == restored.components.map { $0.footprintIndices })
        #expect(restored.footprints.allSatisfy { $0.declaredNet != nil })
    }

    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func allOrientationsWriteReadExactNamedNativeFootprints(_ orientation: String) throws {
        let tech = fixture.technology(), converter = MaskDataFormatConverter(tech: tech)
        let document = try converter.importFromData(fixture.source(
            routes: "+ FIXED metH ( -6500 3300 ) hv \(orientation)", dbu: 2000))
        let url = outputURL()
        defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record("Cleanup failed: \(error)") } }
        try converter.exportDocument(document, to: url, format: .def)
        let data = try Data(contentsOf: url), source = try DEFLibraryReader.read(data)
        #expect(source.dbuPerMicron == 2000 && source.nets.count == 1)
        let wire = try #require(source.nets.first?.routing.first)
        #expect(wire.layerName == "metH" && wire.status == .fixed && wire.viaName == "hv")
        #expect(wire.points == [.init(x: -6500, y: 3300)])
        #expect(wire.viaOrientation.rawValue == orientation)
        let restored = try converter.importFromData(data)
        #expect(restored.units == document.units)
        #expect(restored.cells[0].shapes.isEmpty && restored.cells[0].vias.count == 1)
        #expect(restored.cells[0].vias[0].viaDefinitionID == "hv")
        #expect(restored.cells[0].vias[0].position == document.cells[0].vias[0].position)
        #expect(restored.cells[0].vias[0].properties == document.cells[0].vias[0].properties)
        #expect(restored.cells[0].nets.map(\.name) == ["N"])
        try compareNative(document, restored, tech: tech)
    }

    @Test func terminalNormalAndSpecialSourceIntentSurvivesWithoutDuplicateGeometry() throws {
        let tech = fixture.technology(), converter = MaskDataFormatConverter(tech: tech)
        for special in [false, true] {
            let width = special ? " 200 + SHAPE STRIPE" : ""
            let original = try converter.importFromData(fixture.source(
                routes: "+ FIXED metH\(width) ( 0 0 ) ( 1000 * ) hv FW", special: special))
            let url = outputURL()
            defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record("Cleanup failed: \(error)") } }
            try converter.exportDocument(original, to: url, format: .def)
            let data = try Data(contentsOf: url), source = try DEFLibraryReader.read(data)
            if special {
                #expect(source.nets.isEmpty && source.specialNets.count == 1)
                let placement = try #require(source.specialNets[0].routing.first { $0.points.last?.viaName == "hv" })
                #expect(placement.status == .fixed && placement.layerName == "metH")
                #expect(placement.width == 200 && placement.shape == .stripe)
                #expect(placement.points.first?.x == 1000 && placement.points.first?.y == 0)
            } else {
                #expect(source.specialNets.isEmpty && source.nets.count == 1)
                let placement = try #require(source.nets[0].routing.first { $0.viaName == "hv" })
                #expect(placement.status == .fixed && placement.layerName == "metH")
                #expect(placement.points == [.init(x: 1000, y: 0)])
            }
            let restored = try converter.importFromData(data)
            #expect(restored.cells[0].shapes.count == 1 && restored.cells[0].vias.count == 1)
            #expect(restored.cells[0].vias[0].properties == original.cells[0].vias[0].properties)
            #expect(restored.cells[0].nets.map(\.name) == ["N"])
            try compareNative(original, restored, tech: tech)
        }
    }

    @Test func nativePolicyComposesDeclaredPoseAndUsesExplicitBottomLayer() throws {
        let tech = fixture.technology(), net = LayoutNet(name: "bound")
        let via = LayoutVia(viaDefinitionID: "hv", position: .init(x: 2, y: 3), netID: net.id,
            geometryTransforms: [.init(rotationDegrees: 90, mirrorX: true, mirrorY: true),
                                 .init(rotationDegrees: 270, mirrorY: true)],
            properties: ["source.annotation": "value"])
        let cell = LayoutCell(name: "TOP", vias: [via], nets: [net])
        let original = LayoutDocument(name: "native", cells: [cell], topCellID: cell.id)
        let converter = MaskDataFormatConverter(tech: tech), url = outputURL()
        defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record("Cleanup failed: \(error)") } }
        try converter.exportDocument(original, to: url, format: .def)
        let source = try DEFLibraryReader.read(Data(contentsOf: url))
        let placement = try #require(source.nets.first?.routing.first)
        #expect(source.nets.first?.name == "bound" && placement.status == .routed)
        #expect(placement.layerName == "metH" && placement.viaName == "hv")
        let restored = try converter.importDocument(from: url, format: .def)
        try compareNative(original, restored, tech: tech)
    }

    @Test func invalidBindingsAndPosesFailBeforeReplacingOutput() throws {
        let tech = fixture.technology(), net = LayoutNet(name: "bound")
        let baseline = LayoutVia(viaDefinitionID: "hv", position: .zero, netID: net.id)
        var missing = baseline; missing.viaDefinitionID = "unknown"
        var unbound = baseline; unbound.netID = nil
        var unknownNet = baseline; unknownNet.netID = UUID()
        var partial = baseline; partial.properties = ["def.route.kind": "specialNet"]
        var conflict = baseline; conflict.properties = ["def.route.kind": "net", "def.route.status": "ROUTED",
            "def.route.netName": "other", "def.route.layerName": "metH"]
        var invalidLayer = conflict; invalidLayer.properties["def.route.netName"] = "bound"
        invalidLayer.properties["def.route.layerName"] = "cutHV"
        var specialWidth = invalidLayer; specialWidth.properties["def.route.layerName"] = "metH"
        specialWidth.properties["def.route.kind"] = "specialNet"
        var nonfinite = baseline; nonfinite.position.x = .nan
        let invalid = [missing, unbound, unknownNet, partial, conflict, invalidLayer, specialWidth, nonfinite,
            LayoutVia(viaDefinitionID: "hv", position: .zero, netID: net.id,
                geometryTransforms: [.init(rotationDegrees: 45)]),
            LayoutVia(viaDefinitionID: "hv", position: .zero, netID: net.id,
                geometryTransforms: [.init(magnification: 2)]),
            LayoutVia(viaDefinitionID: "hv", position: .zero, netID: net.id,
                geometryTransforms: [.init(translation: .init(x: 1, y: 0))])]
        let url = outputURL(), preserved = Data("previous-complete-file".utf8)
        defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record("Cleanup failed: \(error)") } }
        try preserved.write(to: url)
        for via in invalid {
            let cell = LayoutCell(name: "TOP", vias: [via], nets: [net])
            let document = LayoutDocument(name: "invalid", cells: [cell], topCellID: cell.id)
            #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: .def) }
            #expect(try Data(contentsOf: url) == preserved)
        }
        let child = LayoutCell(name: "CHILD", vias: [baseline], nets: [net]), top = LayoutCell(name: "TOP")
        let hierarchy = LayoutDocument(name: "child", cells: [top, child], topCellID: top.id)
        #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: tech).exportDocument(hierarchy, to: url, format: .def) }
        var duplicate = tech; duplicate.vias.append(tech.vias[0])
        let cell = LayoutCell(name: "TOP", vias: [baseline], nets: [net])
        let document = LayoutDocument(name: "duplicate", cells: [cell], topCellID: cell.id)
        #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: duplicate).exportDocument(document, to: url, format: .def) }
        #expect(try Data(contentsOf: url) == preserved)
    }
}
