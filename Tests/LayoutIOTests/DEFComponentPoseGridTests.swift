import Foundation
import Testing
import DEF
import LEF
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIO

@Suite("Exact source-bound DEF component pose grid", .timeLimit(.minutes(1)))
struct DEFComponentPoseGridTests {
    private func componentSource(orientation: String, x: Int32 = 10400, y: Int32 = 10000) -> Data {
        Data("""
        VERSION 5.8 ; DESIGN TOP ; UNITS DISTANCE MICRONS 1000 ;
        COMPONENTS 1 ; - U1 INV + PLACED ( \(x) \(y) ) \(orientation) ; END COMPONENTS
        NETS 1 ; - N ( U1 A ) ; END NETS END DESIGN
        """.utf8)
    }

    private func sourceLibrary(width: String = "1.8", portMinX: String = "0.2") throws -> LEFDocument {
        try LEFLibraryReader.read(Data("""
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO INV CLASS CORE ; SIZE \(width) BY 8.9 ; SYMMETRY X Y R90 ;
        PIN A DIRECTION INPUT ; USE SIGNAL ; PORT LAYER M1 ;
        RECT \(portMinX) 0.4 0.8 1.2 ; END END A
        END INV END LIBRARY
        """.utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("def-component-pose-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Cleanup failed: \(error)") }
    }

    private func requireSourceRefusal(_ operation: () throws -> Void) throws {
        do {
            try operation()
            Issue.record("Unrepresentable source component arithmetic must be refused")
        } catch LayoutIOError.unsupportedSourcePin(let message) {
            #expect(!message.isEmpty)
        }
    }

    private func assertCapturedPort(
        _ document: LayoutDocument,
        translation: [Int64],
        bounds: [Int64]
    ) throws -> LayoutConductorSnapshot {
        #expect(document.units.scale.databaseUnitsPerMicrometer == 1000)
        let root = try #require(document.topCellID.flatMap { document.cell(withID: $0) })
        #expect(root.name == "TOP" && root.instances.count == 1 && root.nets.count == 1)
        let instance = try #require(root.instances.first)
        #expect(instance.name == "U1")
        #expect(instance.transform.translation.x == Double(translation[0]) / 1000)
        #expect(instance.transform.translation.y == Double(translation[1]) / 1000)
        let master = try #require(document.cell(withID: instance.cellID))
        #expect(master.name == "INV")
        #expect(master.properties["lef.macro.widthMicrometers"] == "1.8")
        #expect(master.properties["lef.macro.heightMicrometers"] == "8.9")
        #expect(master.pins.count == 1 && master.shapes.count == 1)
        #expect(master.shapes.first?.properties["lef.pin.name"] == "A")
        let net = try #require(root.nets.first)
        #expect(net.name == "N" && instance.terminalNetIDs["A"] == net.id)

        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let capture = try LayoutConnectivityExtractor().captureConductors(
            document: document, tech: .standard(), conductiveLayers: [layer])
        let occurrence = try #require(capture.hierarchy.occurrences.first {
            $0.path.last?.instanceID == instance.id
        })
        let pinIndex = try #require(occurrence.pinRange.first {
            capture.hierarchy.pins[$0].name == "A"
        })
        #expect(capture.hierarchy.pins[pinIndex].direction == .input)
        let pin = try #require(capture.pins.first { $0.sourcePinIndex == pinIndex })
        #expect(pin.declaredNet?.occurrenceIndex == 0 && pin.declaredNet?.netID == net.id)
        #expect(pin.bands.count == 1 && !pin.footprintIndices.isEmpty && !pin.componentIndices.isEmpty)
        let band = try #require(pin.bands.first)
        let scale = try #require(Int64(exactly: capture.coordinateUnits.scale.databaseUnitsPerMicrometer))
        // Expected bounds are independently derived in original DEF DBU. Capture owns its scale.
        for (actual, expected) in zip([band.minX, band.minY, band.maxX, band.maxY], bounds) {
            #expect(Int64(actual) * 1000 == expected * scale)
        }
        for index in pin.footprintIndices {
            let footprint = capture.footprints[index]
            #expect(footprint.layer == layer && !footprint.isCut)
            #expect(footprint.occurrenceIndex == pin.occurrenceIndex)
            #expect(footprint.declaredNet == pin.declaredNet)
            #expect(footprint.band.minX == band.minX && footprint.band.minY == band.minY)
            #expect(footprint.band.maxX == band.maxX && footprint.band.maxY == band.maxY)
        }
        return capture
    }

    private func assertOriginalPlacement(_ bytes: Data, orientation: String, x: Int32 = 10400) throws {
        let source = try DEFLibraryReader.read(bytes)
        #expect(source.components.count == 1 && source.nets.count == 1)
        let component = try #require(source.components.first)
        #expect(component.name == "U1" && component.macro == "INV")
        #expect(component.x == x && component.y == 10000)
        #expect(component.orientation.rawValue == orientation && component.placementStatus == .placed)
        let net = try #require(source.nets.first)
        #expect(net.name == "N")
        #expect(net.connections == [DEFConnection(componentName: "U1", pinName: "A")])
    }

    @Test(arguments: ["N", "S", "W", "E", "FN", "FS", "FW", "FE"])
    func actualDEFPoseRoundTripsExactCanonicalDBU(orientation: String) throws {
        // SIZE is 1800 x 8900 DBU; the asymmetric PORT is [200,400]-[800,1200].
        // This table is a source-coordinate oracle, independent of converter helpers.
        let expected: [String: ([Int64], [Int64])] = [
            "N": ([10400, 10000], [10600, 10400, 11200, 11200]),
            "S": ([12200, 18900], [11400, 17700, 12000, 18500]),
            "W": ([19300, 10000], [18100, 10200, 18900, 10800]),
            "E": ([10400, 11800], [10800, 11000, 11600, 11600]),
            "FN": ([12200, 10000], [11400, 10400, 12000, 11200]),
            "FS": ([10400, 18900], [10600, 17700, 11200, 18500]),
            "FW": ([10400, 10000], [10800, 10200, 11600, 10800]),
            "FE": ([19300, 11800], [18100, 11000, 18900, 11600]),
        ]
        let oracle = try #require(expected[orientation])
        let converter = MaskDataFormatConverter(tech: .standard(), standardCellLibrary: try sourceLibrary())
        let document = try converter.importFromData(componentSource(orientation: orientation), format: .def)
        let before = try assertCapturedPort(document, translation: oracle.0, bounds: oracle.1)
        let directory = try temporaryDirectory()
        defer { removeDirectory(directory) }
        let output = directory.appendingPathComponent("roundtrip.def")
        try converter.exportDocument(document, to: output, format: .def)
        try assertOriginalPlacement(Data(contentsOf: output), orientation: orientation)
        let restored = try converter.importDocument(from: output, format: .def)
        let after = try assertCapturedPort(restored, translation: oracle.0, bounds: oracle.1)
        #expect(after.footprints.map(\.band) == before.footprints.map(\.band))
        #expect(after.pins.map(\.bands) == before.pins.map(\.bands))
        #expect(after.contacts == before.contacts)
    }

    @Test func exportsSmallOriginalPlacementWithoutFloatingCancellation() throws {
        let converter = MaskDataFormatConverter(tech: .standard(), standardCellLibrary: try sourceLibrary())
        let document = try converter.importFromData(componentSource(orientation: "FN", x: 1), format: .def)
        _ = try assertCapturedPort(document, translation: [1801, 10000], bounds: [1001, 10400, 1601, 11200])
        let directory = try temporaryDirectory()
        defer { removeDirectory(directory) }
        let output = directory.appendingPathComponent("small-placement.def")
        try converter.exportDocument(document, to: output, format: .def)
        try assertOriginalPlacement(Data(contentsOf: output), orientation: "FN", x: 1)
        let restored = try converter.importDocument(from: output, format: .def)
        _ = try assertCapturedPort(restored, translation: [1801, 10000], bounds: [1001, 10400, 1601, 11200])
    }

    @Test(arguments: ["off-grid-size", "near-grid-size", "near-grid-rect", "normalization-overflow", "denormalization-overflow"])
    func rejectsNonRepresentableComponentPoseArithmetic(scenario: String) throws {
        var library = try sourceLibrary()
        switch scenario {
        case "off-grid-size":
            library = try sourceLibrary(width: "1.8005")
            #expect(library.macros.first?.width == 1.8005)
        case "near-grid-size":
            library = try sourceLibrary(width: String(1.8.nextUp))
            #expect(library.macros.first?.width == 1.8.nextUp)
        case "near-grid-rect":
            library = try sourceLibrary(portMinX: String(0.2.nextUp))
            #expect(library.macros.first?.pins.first?.ports.first?.rects.first?.x1 == 0.2.nextUp)
        case "normalization-overflow", "denormalization-overflow":
            break
        default:
            Issue.record("Unknown arithmetic refusal scenario")
            return
        }
        let converter = MaskDataFormatConverter(tech: .standard(), standardCellLibrary: library)
        if scenario == "denormalization-overflow" {
            var document = try converter.importFromData(componentSource(orientation: "S"), format: .def)
            let rootIndex = try #require(document.cells.firstIndex { $0.id == document.topCellID })
            // Source S requires subtracting width 1800 from this admitted canonical DBU value.
            document.cells[rootIndex].instances[0].transform.translation.x = Double(Int32.min) / 1000
            let directory = try temporaryDirectory()
            defer { removeDirectory(directory) }
            let output = directory.appendingPathComponent("retained.def")
            let retained = Data("retained previous standard output".utf8)
            try retained.write(to: output)
            try requireSourceRefusal { try converter.exportDocument(document, to: output, format: .def) }
            #expect(try Data(contentsOf: output) == retained)
        } else {
            let source = scenario == "normalization-overflow"
                ? componentSource(orientation: "S", x: Int32.max)
                : componentSource(orientation: "N")
            try requireSourceRefusal { _ = try converter.importFromData(source, format: .def) }
        }
    }
}
