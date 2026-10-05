import Foundation
import Testing
import GDSII
import LEF
import LayoutIR
import LayoutCore
import LayoutTech
import LayoutVerify
@testable import LayoutIO

@Suite("Retained full-mask DEF masters", .timeLimit(.minutes(1)))
struct DEFMasterCompositionTests {
    private func rectangle(_ layer: Int16, _ x1: Int32, _ y1: Int32, _ x2: Int32, _ y2: Int32) -> IRElement {
        .boundary(.init(layer: layer, datatype: 0, points: [
            .init(x: x1, y: y1), .init(x: x2, y: y1), .init(x: x2, y: y2),
            .init(x: x1, y: y2), .init(x: x1, y: y1)]))
    }

    private func mask() throws -> IRLibrary {
        let units = LayoutTechDatabase.sampleProcess().units.scale
        let master = IRCell(name: "INV", elements: [
            rectangle(1, 100, 100, 300, 300), rectangle(1, 1700, 100, 1900, 300),
            .text(.init(layer: 1, position: .init(x: 200, y: 200), string: "retained-terminal")),
            .cellRef(.init(cellName: "device-body", origin: .init(x: 500, y: 400),
                transform: .init(mirrorX: true, angle: 90)))])
        let child = IRCell(name: "device-body", elements: [
            rectangle(20, 0, 0, 200, 600), rectangle(30, 50, 100, 150, 500),
            rectangle(40, 0, 0, 200, 600)])
        let source = IRLibrary(name: "baseline", databaseUnitScale: units, cells: [master, child])
        // Actual standard bytes, including the transitive device body and asymmetric pose.
        return try GDSLibraryReader.read(GDSLibraryWriter.write(source))
    }

    private func lef() throws -> LEFDocument {
        try LEFLibraryReader.read(Data("""
        VERSION 5.8 ; UNITS DATABASE MICRONS 1000 ; END UNITS
        MACRO INV CLASS CORE ; SIZE 2 BY 1 ; ORIGIN 0 0 ;
          PIN A DIRECTION INPUT ; USE SIGNAL ; PORT LAYER M1 ; RECT 0.1 0.1 0.3 0.3 ; END END A
          PIN Y DIRECTION OUTPUT ; USE SIGNAL ; PORT LAYER M1 ; RECT 1.7 0.1 1.9 0.3 ; END END Y
        END INV END LIBRARY
        """.utf8))
    }

    private func def(_ pose: String = "N") -> Data {
        Data("""
        VERSION 5.8 ; DESIGN top ; UNITS DISTANCE MICRONS 1000 ;
        COMPONENTS 1 ; - U1 INV + PLACED ( 5000 6000 ) \(pose) ; END COMPONENTS
        NETS 2 ; - input ( U1 A ) ; - output ( U1 Y ) ; END NETS END DESIGN
        """.utf8)
    }

    @Test func retainedGDSBodyAndLabelsAreComposedBeforeDEFPublication() throws {
        let source = try mask()
        let converter = MaskDataFormatConverter(tech: .sampleProcess(), standardCellLibrary: try lef(), standardCellLibraryMask: source)
        let document = try converter.importFromData(def(), format: .def)
        let master = try #require(document.cells.first { $0.name == "INV" })
        let child = try #require(document.cells.first { $0.name == "device-body" })
        #expect(master.shapes.count == 2 && master.pins.count == 2)
        #expect(master.labels.map(\.text) == ["retained-terminal"])
        #expect(master.instances.count == 1 && child.shapes.count == 3)
        #expect(master.instances.first?.cellID == child.id)
        #expect(child.shapes.map(\.layer.name) == ["ACTIVE", "POLY", "NIMP"])
        #expect(master.shapes.allSatisfy { $0.netID != nil })
    }
    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func eightPosesRetainNativeBodyHierarchyAndStandardGDS(_ pose: String) throws {
        let matrices: [String: (Int32, Int32, Int32, Int32)] = [
            "N": (1,0,0,1), "S": (-1,0,0,-1), "E": (0,1,-1,0), "W": (0,-1,1,0),
            "FN": (-1,0,0,1), "FS": (1,0,0,-1), "FE": (0,-1,-1,0), "FW": (0,1,1,0)]
        let matrix = try #require(matrices[pose])
        let converter = MaskDataFormatConverter(tech: .sampleProcess(), standardCellLibrary: try lef(), standardCellLibraryMask: try mask())
        let document = try converter.importFromData(def(pose), format: .def)
        let captured = try LayoutConnectivityExtractor().captureHierarchy(document: document)
        let body = try #require(captured.shapes.first { $0.layer.name == "ACTIVE" })
        let frame: [(Int32, Int32)] = [(0,0), (2000,0), (0,1000), (2000,1000)]
        let minX = try #require(frame.map { matrix.0 * $0.0 + matrix.1 * $0.1 }.min())
        let minY = try #require(frame.map { matrix.2 * $0.0 + matrix.3 * $0.1 }.min())
        // Independently resolve the retained child (mirror about X, then 90 degrees).
        let local: [(Int32, Int32)] = [(500,400), (500,600), (1100,600), (1100,400)]
        let expected = Set(local.map { IRPoint(x: 5000 + matrix.0 * $0.0 + matrix.1 * $0.1 - minX,
            y: 6000 + matrix.2 * $0.0 + matrix.3 * $0.1 - minY) })
        guard case .polygon(let polygon) = body.geometry else { Issue.record("Retained body polygon missing"); return }
        #expect(Set(polygon.points.map { IRPoint(x: Int32(($0.x * 1000).rounded()), y: Int32(($0.y * 1000).rounded())) }) == expected)
        #expect(captured.occurrences.count == 3 && captured.shapes.count == 5)
        let root = try #require(document.topCellID.flatMap { document.cell(withID: $0) })
        let instance = try #require(root.instances.first)
        #expect(instance.terminalNetIDs["A"] == root.nets.first { $0.name == "input" }?.id)
        #expect(instance.terminalNetIDs["Y"] == root.nets.first { $0.name == "output" }?.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("full-master-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let output = directory.appendingPathComponent("candidate.gds")
        try converter.exportDocument(document, to: output, format: .gds)
        let restored = try converter.importDocument(from: output, format: .gds)
        let after = try LayoutConnectivityExtractor().captureHierarchy(document: restored)
        #expect(after.shapes.map(\.geometry) == captured.shapes.map(\.geometry))
        #expect(after.shapes.map(\.layer) == captured.shapes.map(\.layer))
        #expect(restored.cells.first { $0.name == "INV" }?.labels.map(\.text) == ["retained-terminal"])
        #expect(after.occurrences.count == captured.occurrences.count)
        let defOutput = directory.appendingPathComponent("candidate.def")
        let sentinel = Data("previous-immutable-artifact".utf8)
        try sentinel.write(to: defOutput)
        #expect(throws: LayoutIOError.self) { try converter.exportDocument(document, to: defOutput, format: .def) }
        #expect(try Data(contentsOf: defOutput) == sentinel)
    }

    @Test(arguments: ["missing", "duplicate", "missing-child", "duplicate-child", "cycle", "top-collision", "units", "lef-units", "tech-units", "layer", "ambiguous-layer", "size", "origin", "port", "duplicate-port", "crossed-port", "terminal-alias", "text-pose", "empty"])
    func incompatibleRetainedSourceFailsAtomically(_ mode: String) throws {
        var source = try mask(), library = try lef(), tech = LayoutTechDatabase.sampleProcess()
        switch mode {
        case "missing": source.cells.removeFirst()
        case "duplicate": source.cells.append(source.cells[0])
        case "missing-child": source.cells.removeLast()
        case "duplicate-child": source.cells.append(source.cells[1])
        case "cycle": source.cells[1].elements.append(.cellRef(.init(cellName: "INV", origin: .init(x: 0, y: 0))))
        case "top-collision": source.cells[1].name = "top"; source.cells[0].elements[3] = .cellRef(.init(cellName: "top", origin: .init(x: 0, y: 0)))
        case "units": source.databaseUnitScale = try .init(databaseUnitsPerMicrometer: 2000)
        case "lef-units": library.dbuPerMicron = 2000
        case "tech-units": tech.units = .init(scale: try .init(databaseUnitsPerMicrometer: 2000))
        case "layer": source.cells[1].elements[0] = rectangle(127, 0, 0, 200, 600)
        case "ambiguous-layer": tech.layers.append(try #require(tech.layers.first { $0.id.name == "M1" }))
        case "size": library.macros[0].width = 0.8
        case "origin": library.macros[0].origin = .init(x: 0.1, y: 0)
        case "port": library.macros[0].pins[0].ports[0].rects[0].x2 = 0.4
        case "duplicate-port": source.cells[0].elements.append(source.cells[0].elements[0])
        case "crossed-port": source.cells[0].elements[0] = .boundary(.init(layer: 1, datatype: 0, points: [
            .init(x: 100, y: 100), .init(x: 300, y: 300), .init(x: 100, y: 300), .init(x: 300, y: 100), .init(x: 100, y: 100)]))
        case "terminal-alias": library.macros[0].pins[1].ports = library.macros[0].pins[0].ports
        case "text-pose": source.cells[0].elements[2] = .text(.init(layer: 1, transform: .init(angle: 90), position: .init(x: 200, y: 200), string: "rotated"))
        case "empty": source.cells[0].elements = []
        default: Issue.record("Unknown fixture mode"); return
        }
        let converter = MaskDataFormatConverter(tech: tech, standardCellLibrary: library, standardCellLibraryMask: source)
        var published: LayoutDocument?
        do {
            published = try converter.importFromData(def(), format: .def)
            Issue.record("Incompatible retained source was published: \(mode)")
        } catch LayoutIOError.incompatibleStandardCellMask { }
          catch LayoutIOError.unsupportedStandardCellMask { }
          catch LayoutIOError.unsupportedSourcePin { }
        #expect(published == nil)
    }

    @Test func abstractLEFLaneDoesNotClaimFullDeviceGeometry() throws {
        let document = try MaskDataFormatConverter(tech: .sampleProcess(), standardCellLibrary: try lef()).importFromData(def(), format: .def)
        let master = try #require(document.cells.first { $0.name == "INV" })
        #expect(master.shapes.count == 2 && master.instances.isEmpty && master.labels.isEmpty)
        #expect(document.cells.count == 2)
    }

    @Test func retainedArrayUsesActualReferencePoseAndBoundedExtrema() throws {
        var source = try mask()
        source.cells[0].elements[3] = .arrayRef(.init(cellName: "device-body",
            transform: .init(mirrorX: true, angle: 90), columns: 2, rows: 1,
            referencePoints: [.init(x: 500, y: 400), .init(x: 1500, y: 400), .init(x: 500, y: 600)]))
        let converter = MaskDataFormatConverter(tech: .sampleProcess(), standardCellLibrary: try lef(), standardCellLibraryMask: source)
        let document = try converter.importFromData(def(), format: .def)
        let captured = try LayoutConnectivityExtractor().captureHierarchy(document: document)
        #expect(captured.occurrences.count == 4 && captured.shapes.count == 8)
        let bodies = captured.shapes.filter { $0.layer.name == "ACTIVE" }.map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        #expect(bodies.count == 2)
        #expect(abs(bodies[1].minX - bodies[0].minX - 0.5) <= 0.5.ulp)
        let master = try #require(document.cells.first { $0.name == "INV" })
        #expect(master.instances.first?.repetition?.columns == 2)
        source.cells[0].elements[3] = .arrayRef(.init(cellName: "device-body", columns: 2, rows: 1,
            referencePoints: [.init(x: 500, y: 400), .init(x: 5000, y: 400), .init(x: 500, y: 600)]))
        #expect(throws: LayoutIOError.self) {
            _ = try MaskDataFormatConverter(tech: .sampleProcess(), standardCellLibrary: lef(), standardCellLibraryMask: source).importFromData(def(), format: .def)
        }
    }

}
