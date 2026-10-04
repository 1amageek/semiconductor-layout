import Foundation
import CryptoKit
import Testing
import LEF
import DEF
import LayoutCore
import LayoutTech
import LayoutVerify
@testable import LayoutIO

@Suite("Source-bound DEF pins", .timeLimit(.minutes(1)))
struct DEFBoundPinTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BoundDEF/\(name)")
        return try Data(contentsOf: url)
    }

    private func library() throws -> LEFDocument { try LEFLibraryReader.read(fixture("cells.lef")) }

    private func technology() throws -> LayoutTechDatabase {
        var ir = try LEFTechIRConverter.toIRTechLibrary(LEFLibraryReader.read(fixture("technology.lef")))
        // These are the retained native process layer declarations, not port inference.
        let numbers = ["metH": 2, "cutHV": 4, "metV": 3]
        for index in ir.layers.indices { ir.layers[index].gdsLayer = numbers[ir.layers[index].name] }
        return try IRTechLayoutConverter().importTechLibrary(ir)
    }

    private func componentSource(orientation: String = "N", connection: String = "( U1 Y )") -> Data {
        Data("""
        VERSION 5.8 ; DESIGN top ; UNITS DISTANCE MICRONS 1000 ;
        COMPONENTS 1 ; - U1 INV_X1 + PLACED ( 500 1000 ) \(orientation) ; END COMPONENTS
        NETS 1 ; - N \(connection) ; END NETS END DESIGN
        """.utf8)
    }

    @Test func missingLibraryFailsBeforePublishingEmptyConnectedMaster() throws {
        do {
            _ = try MaskDataFormatConverter(tech: technology()).importFromData(componentSource(), format: .def)
            Issue.record("Connected DEF master requires a selected source library")
        } catch LayoutIOError.missingStandardCellLibrary { }
    }

    @Test func actualNativeSourcePinsHaveExactGeometryDirectionAndContactIncidence() throws {
        let cells = try fixture("cells.lef"), bytes = try fixture("native-route-input.def")
        #expect(cells.count == 372)
        #expect(SHA256.hash(data: cells).map { String(format: "%02x", $0) }.joined() == "849d86d0b9796f572422987b5d991889ff951b7dc97de10c06873c53061d4275")
        let tech = try technology()
        let converter = MaskDataFormatConverter(tech: tech, standardCellLibrary: try library())
        let document = try converter.importFromData(bytes, format: .def)
        let root = try #require(document.topCellID.flatMap { document.cell(withID: $0) })
        let master = try #require(document.cells.first { $0.name == "INV_X1" })
        #expect(master.properties["lef.macro.widthMicrometers"] == "2.0")
        #expect(master.properties["lef.macro.heightMicrometers"] == "1.0")
        #expect(master.shapes.count == 2 && master.pins.count == 2)
        #expect(master.shapes.allSatisfy { $0.properties["lef.pin.name"] != nil })
        #expect(root.pins.isEmpty && root.labels.isEmpty && root.instances.count == 2)
        #expect(root.shapes.allSatisfy { $0.properties["def.route.kind"] != nil })
        #expect(root.properties["def.dieArea"] != nil)
        let net = try #require(root.nets.first { $0.name == "N" })
        let capture = try LayoutConnectivityExtractor().captureConductors(document: document,
            tech: tech, conductiveLayers: [.init(name: "metH", purpose: "drawing"), .init(name: "metV", purpose: "drawing")])
        for (name, terminal, expectedDirection, bounds) in [
            ("U1", "Y", LayoutPinDirection.output, [1.7, 1.1, 2.3, 1.7]),
            ("U2", "A", LayoutPinDirection.input, [6.3, 3.1, 6.9, 3.7]),
        ] {
            let instance = try #require(root.instances.first { $0.name == name })
            #expect(instance.terminalNetIDs[terminal] == net.id && instance.cellID == master.id)
            let occurrence = try #require(capture.hierarchy.occurrences.first { $0.path.last?.instanceID == instance.id })
            let pinIndex = try #require(occurrence.pinRange.first { capture.hierarchy.pins[$0].name == terminal })
            let pin = capture.hierarchy.pins[pinIndex]
            #expect(pin.direction == expectedDirection)
            let box = LayoutGeometryAnalysis.boundingBox(for: capture.hierarchy.pinGeometries[pinIndex])
            for (actual, expected) in zip([box.minX, box.minY, box.maxX, box.maxY], bounds) { #expect(abs(actual - expected) < 1e-12) }
            let contact = try #require(capture.pins.first { $0.sourcePinIndex == pinIndex })
            #expect(!contact.footprintIndices.isEmpty)
            #expect(contact.componentIndices.contains { componentIndex in
                capture.components[componentIndex].footprintIndices.contains { index in
                    capture.footprints[index].occurrenceIndex == 0
                }
            })
            #expect(contact.declaredNet?.netID == net.id)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-bound-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let output = directory.appendingPathComponent("native.def")
        try converter.exportDocument(document, to: output, format: .def)
        let originalSource = try DEFLibraryReader.read(bytes), restoredSource = try DEFLibraryReader.read(Data(contentsOf: output))
        #expect(restoredSource.dieArea == originalSource.dieArea)
        let restored = try converter.importDocument(from: output, format: .def)
        let after = try LayoutConnectivityExtractor().captureConductors(document: restored, tech: tech,
            conductiveLayers: [.init(name: "metH", purpose: "drawing"), .init(name: "metV", purpose: "drawing")])
        #expect(after.hierarchy.pinGeometries == capture.hierarchy.pinGeometries)
        #expect(after.footprints.map(\.band) == capture.footprints.map(\.band))
        #expect(after.contacts == capture.contacts)
    }

    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func allPosesNormalizeSourceSizeAndRoundTripActualPorts(_ orientation: String) throws {
        let matrices: [String: (Double, Double, Double, Double)] = [
            "N": (1,0,0,1), "S": (-1,0,0,-1), "E": (0,1,-1,0), "W": (0,-1,1,0),
            "FN": (-1,0,0,1), "FS": (1,0,0,-1), "FE": (0,-1,-1,0), "FW": (0,1,1,0),
        ]
        let m = try #require(matrices[orientation]), source = try library(), tech = try technology()
        let converter = MaskDataFormatConverter(tech: tech, standardCellLibrary: source)
        let document = try converter.importFromData(componentSource(orientation: orientation), format: .def)
        let root = try #require(document.topCellID.flatMap { document.cell(withID: $0) })
        let instance = try #require(root.instances.first)
        let master = try #require(document.cell(withID: instance.cellID))
        let corners = [(0.0,0.0),(2.0,0.0),(0.0,1.0),(2.0,1.0)]
        let minX = try #require(corners.map { m.0 * $0.0 + m.1 * $0.1 }.min())
        let minY = try #require(corners.map { m.2 * $0.0 + m.3 * $0.1 }.min())
        for pin in master.pins {
            let actual = pin.transformed(by: [instance.transform])
            #expect(abs(actual.position.x - (m.0 * pin.position.x + m.1 * pin.position.y - minX + 0.5)) < 1e-12)
            #expect(abs(actual.position.y - (m.2 * pin.position.x + m.3 * pin.position.y - minY + 1)) < 1e-12)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bound-ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let output = directory.appendingPathComponent("ports.def")
        try converter.exportDocument(document, to: output, format: .def)
        let parsed = try DEFLibraryReader.read(Data(contentsOf: output))
        #expect(parsed.components.first?.orientation.rawValue == orientation)
        #expect(parsed.components.first?.x == 500 && parsed.components.first?.y == 1000)
        let restored = try converter.importDocument(from: output, format: .def)
        let before = try LayoutConnectivityExtractor().captureHierarchy(document: document)
        let after = try LayoutConnectivityExtractor().captureHierarchy(document: restored)
        #expect(before.pinGeometries == after.pinGeometries)
        #expect(before.pins.map(\.direction) == after.pins.map(\.direction))
        let restoredRoot = try #require(restored.topCellID.flatMap { restored.cell(withID: $0) })
        let bindingNames = before.occurrences.map { $0.terminalNetIDs.mapValues { id in root.nets.first { $0.id == id }?.name } }
        let restoredBindingNames = after.occurrences.map { $0.terminalNetIDs.mapValues { id in restoredRoot.nets.first { $0.id == id }?.name } }
        #expect(bindingNames == restoredBindingNames)
        #expect(bindingNames.last?["Y"] == "N")
    }

    @Test(arguments: ["missing-master", "duplicate-master", "missing-pin", "duplicate-pin", "missing-size", "nonzero-origin", "multi-rect", "multi-layer", "polygon", "via", "direction", "zero-wildcard"])
    func unsupportedOrUnresolvedSourceFails(_ mode: String) throws {
        var selected = try library(), bytes = componentSource()
        switch mode {
        case "missing-master": selected.macros = []
        case "duplicate-master": selected.macros.append(selected.macros[0])
        case "missing-pin": bytes = componentSource(connection: "( U1 missing )")
        case "duplicate-pin": selected.macros[0].pins.append(selected.macros[0].pins[0])
        case "missing-size": selected.macros[0].width = nil
        case "nonzero-origin": selected.macros[0].origin = .init(x: 0.1, y: 0)
        case "multi-rect": selected.macros[0].pins[0].ports[0].rects.append(.init(x1: 0, y1: 0, x2: 0.2, y2: 0.2))
        case "multi-layer": selected.macros[0].pins[0].ports.append(.init(layerName: "metV", rects: [.init(x1: 0, y1: 0, x2: 0.2, y2: 0.2)]))
        case "polygon": selected.macros[0].pins[0].ports[0].polygons = [[.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1)]]
        case "via": selected.macros[0].pins[0].ports[0].vias = [.init(viaName: "hv", point: .init(x: 0, y: 0))]
        case "direction": selected.macros[0].pins[0].direction = nil
        default: bytes = componentSource(connection: "( * missing )")
        }
        #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: technology(), standardCellLibrary: selected).importFromData(bytes, format: .def) }
    }

    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func declaredTopPinsAreConductorsAndUnresolvedDeclarationsFail(_ orientation: String) throws {
        let source = Data("""
        VERSION 5.8 ; DESIGN top ; UNITS DISTANCE MICRONS 1000 ;
        PINS 1 ; - P + NET N + DIRECTION INPUT + USE SIGNAL + LAYER metH ( -100 -200 ) ( 300 400 ) + FIXED ( 500 1000 ) \(orientation) + SPECIAL + PROPERTY owner retained ; END PINS
        NETS 1 ; - N ( PIN P ) + ROUTED metH ( 500 1000 ) ( 1500 1000 ) ; END NETS END DESIGN
        """.utf8)
        let converter = MaskDataFormatConverter(tech: try technology())
        let document = try converter.importFromData(source, format: .def)
        let root = try #require(document.topCellID.flatMap { document.cell(withID: $0) })
        #expect(root.pins.count == 1 && root.labels.isEmpty)
        #expect(root.shapes.filter { $0.properties["def.pin.name"] == "P" }.count == 1)
        let pin = try #require(root.pins.first)
        #expect(pin.direction == .input)
        let ir = DEFIRConverter.orientationToTransform(try #require(DEFOrientation(rawValue: orientation)))
        let expected = LayoutTransform(translation: .init(x: 0.5, y: 1), rotationDegrees: ir.angle, mirrorY: ir.mirrorX).apply(to: .init(x: 0.1, y: 0.1))
        #expect(abs(pin.position.x - expected.x) < 1e-12 && abs(pin.position.y - expected.y) < 1e-12)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bound-top-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let output = directory.appendingPathComponent("pins.def")
        try converter.exportDocument(document, to: output, format: .def)
        let parsed = try DEFLibraryReader.read(Data(contentsOf: output))
        #expect(parsed.pins.first?.placementStatus == .fixed && parsed.pins.first?.special == true)
        #expect(parsed.pins.first?.properties == [.init(key: "owner", value: "retained")])
        let restored = try converter.importDocument(from: output, format: .def)
        let before = try LayoutConnectivityExtractor().captureConductors(document: document, tech: technology(), conductiveLayers: [.init(name: "metH", purpose: "drawing")])
        let after = try LayoutConnectivityExtractor().captureConductors(document: restored, tech: technology(), conductiveLayers: [.init(name: "metH", purpose: "drawing")])
        #expect(before.footprints.map(\.band) == after.footprints.map(\.band))
        #expect(before.pins.map(\.bands) == after.pins.map(\.bands))
        let dangling = Data("VERSION 5.8 ; DESIGN top ; NETS 1 ; - N ( PIN P ) ; END NETS END DESIGN".utf8)
        #expect(throws: LayoutIOError.self) { try converter.importFromData(dangling, format: .def) }
    }

    @Test func mutatedMasterExportFailsAtomically() throws {
        let converter = MaskDataFormatConverter(tech: try technology(), standardCellLibrary: try library())
        var document = try converter.importFromData(componentSource(), format: .def)
        let index = try #require(document.cells.firstIndex { $0.name == "INV_X1" })
        document.cells[index].pins[0].size.width += 0.1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bound-pin-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let url = directory.appendingPathComponent("output.def"), original = Data("retained previous output".utf8)
        try original.write(to: url)
        #expect(throws: LayoutIOError.self) { try converter.exportDocument(document, to: url, format: .def) }
        #expect(try Data(contentsOf: url) == original)
    }
    @Test(arguments: ["POLYGON metH ( 0 0 ) ( 100 0 ) ( 100 100 )", "VIA ( 0 0 ) hv", "PLACED ( 500 1000 ) INVALID"])
    func rawExtraPinGeometryAndInvalidPoseAreRejected(_ feature: String) throws {
        let bytes = Data("""
        VERSION 5.8 ; DESIGN top ; UNITS DISTANCE MICRONS 1000 ;
        PINS 1 ; - P + NET N + DIRECTION INPUT + LAYER metH ( -100 -100 ) ( 100 100 ) + FIXED ( 500 1000 ) N + \(feature) ; END PINS
        NETS 1 ; - N ( PIN P ) ; END NETS END DESIGN
        """.utf8)
        #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: technology()).importFromData(bytes, format: .def) }
    }

}
