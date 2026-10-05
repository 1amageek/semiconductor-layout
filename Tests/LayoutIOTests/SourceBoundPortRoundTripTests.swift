import Foundation
import Testing
import GDSII
import LayoutIR
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutIO

@Suite("Source-bound DEF ports in standard mask bytes", .timeLimit(.minutes(1)))
struct SourceBoundPortRoundTripTests {
    private func source(_ pose: String = "N", units: Int = 1000) -> Data {
        var text = "VERSION 5.8 ; DESIGN TOP ; UNITS DISTANCE MICRONS \(units) ; PINS 4 ;\n"
        for (index, name) in ["in", "out", "vdd", "vss"].enumerated() {
            let direction = index == 0 ? "INPUT" : index == 1 ? "OUTPUT" : "INOUT"
            let use = index == 2 ? " + USE POWER" : index == 3 ? " + USE GROUND" : ""
            text += " - \(name) + NET net_\(name) + DIRECTION \(direction)\(use) + LAYER M1 ( -100 -200 ) ( 100 200 ) + FIXED ( \(index * 2000) 1000 ) \(pose) ;\n"
        }
        text += "END PINS NETS 4 ;\n"
        for name in ["in", "out", "vdd", "vss"] { text += " - net_\(name) ( PIN \(name) ) ;\n" }
        return Data((text + "END NETS END DESIGN").utf8)
    }

    private func roundTrip(_ document: LayoutDocument, technology: LayoutTechDatabase) throws -> (LayoutDocument, IRLibrary) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-bound-mask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Temporary output cleanup failed: \(error)") }
        }
        let output = directory.appendingPathComponent("actual.gds")
        let converter = MaskDataFormatConverter(tech: technology)
        try converter.exportDocument(document, to: output, format: .gds)
        let bytes = try Data(contentsOf: output)
        return (try converter.importFromData(bytes, format: .gds), try GDSLibraryReader.read(bytes))
    }

    @Test func fourActualSourcePortsSurvivePublicGDSBytesAndConductorCapture() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let original = try MaskDataFormatConverter(tech: tech).importFromData(source(), format: .def)
        let root = try #require(original.cells.first)
        let (restored, library) = try roundTrip(original, technology: tech)
        let after = try #require(restored.cells.first)
        #expect(after.pins.count == 4)
        #expect(after.labels.isEmpty)
        #expect(after.shapes.count == root.shapes.count)
        #expect(after.pins.map(\.id) == root.pins.map(\.id))
        #expect(after.pins.map(\.name) == root.pins.map(\.name))
        #expect(after.pins.map(\.position) == root.pins.map(\.position))
        #expect(after.pins.map(\.size) == root.pins.map(\.size))
        #expect(after.pins.map(\.direction) == root.pins.map(\.direction))
        #expect(after.pins.map(\.role) == root.pins.map(\.role))
        #expect(after.pins.map { pin in after.nets.first { $0.id == pin.netID }?.name } == ["net_in", "net_out", "net_vdd", "net_vss"])
        let texts = library.cells.flatMap(\.elements).compactMap { element -> IRText? in
            guard case .text(let text) = element else { return nil }; return text
        }
        #expect(texts.map(\.string) == ["in", "out", "vdd", "vss"])
        let beforeCapture = try LayoutConnectivityExtractor().captureConductors(document: original, tech: tech,
            conductiveLayers: [.init(name: "M1", purpose: "drawing")])
        let afterCapture = try LayoutConnectivityExtractor().captureConductors(document: restored, tech: tech,
            conductiveLayers: [.init(name: "M1", purpose: "drawing")])
        #expect(afterCapture.footprints.map(\.band) == beforeCapture.footprints.map(\.band))
        #expect(afterCapture.pins.map(\.bands) == beforeCapture.pins.map(\.bands))
        #expect(afterCapture.pins.count == 4 && afterCapture.pins.allSatisfy { !$0.footprintIndices.isEmpty })
    }

    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func actualPortPoseAndDifferentSourceUnitsRemainExact(_ pose: String) throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let original = try MaskDataFormatConverter(tech: tech).importFromData(source(pose, units: 2000), format: .def)
        let (restored, _) = try roundTrip(original, technology: tech)
        #expect(restored.units == original.units)
        #expect(restored.cells.first?.pins.map(\.position) == original.cells.first?.pins.map(\.position))
        #expect(restored.cells.first?.pins.map(\.size) == original.cells.first?.pins.map(\.size))
    }

    @Test(arguments: ["net", "layer", "missing-pin", "duplicate-pin", "duplicate-metal", "duplicate-identity", "duplicate-net", "duplicate-net-name", "geometry", "off-grid", "label"])
    func incorrectCanonicalSourceBindingFailsBeforeAtomicWrite(_ mode: String) throws {
        let tech = LayoutTechDatabase.sampleProcess(), converter = MaskDataFormatConverter(tech: tech)
        var document = try converter.importFromData(source(), format: .def)
        switch mode {
        case "net": document.cells[0].pins[0].netID = document.cells[0].pins[1].netID
        case "layer": document.cells[0].pins[0].layer = .init(name: "M2", purpose: "drawing")
        case "missing-pin": document.cells[0].pins.removeFirst()
        case "duplicate-pin": document.cells[0].pins.append(document.cells[0].pins[0])
        case "duplicate-identity":
            let pin = document.cells[0].pins[1]
            document.cells[0].pins[1] = .init(id: document.cells[0].pins[0].id, name: pin.name, position: pin.position,
                size: pin.size, layer: pin.layer, netID: pin.netID, role: pin.role, direction: pin.direction)
        case "duplicate-net": document.cells[0].nets.append(document.cells[0].nets[0])
        case "duplicate-net-name": document.cells[0].nets.append(.init(name: document.cells[0].nets[0].name))
        case "duplicate-metal": document.cells[0].shapes.append(document.cells[0].shapes[0])
        case "geometry": document.cells[0].shapes[0].geometry = .path(.init(points: [.init(x: -0.1, y: 1), .init(x: 0.1, y: 1)], width: 0.4))
        case "off-grid": document.cells[0].pins[0].position.x += 0.0001
        case "label": document.cells[0].labels.append(.init(text: "in", position: .init(x: 0, y: 1), layer: .init(name: "M1", purpose: "drawing")))
        default: Issue.record("Unknown fixture mode"); return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-port-reject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Temporary output cleanup failed: \(error)") }
        }
        let output = directory.appendingPathComponent("actual.gds"), previous = Data("previous immutable artifact".utf8)
        try previous.write(to: output)
        #expect(throws: LayoutIOError.self) { try converter.exportDocument(document, to: output, format: .gds) }
        #expect(try Data(contentsOf: output) == previous)
    }

    @Test(arguments: ["missing-text", "duplicate-text", "text-name", "text-layer", "text-pose", "net", "duplicate-property", "crossed-boundary", "label"])
    func malformedStandardSourcePairsFailBeforePublication(_ mode: String) throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let original = try MaskDataFormatConverter(tech: tech).importFromData(source(), format: .def)
        var (_, library) = try roundTrip(original, technology: tech)
        let boundaryIndex = try #require(library.cells[0].elements.firstIndex { if case .boundary = $0 { true } else { false } })
        let textIndex = try #require(library.cells[0].elements.firstIndex { if case .text = $0 { true } else { false } })
        guard case .text(var text) = library.cells[0].elements[textIndex],
              case .boundary(var boundary) = library.cells[0].elements[boundaryIndex] else { return }
        switch mode {
        case "missing-text": library.cells[0].elements.remove(at: textIndex)
        case "duplicate-text": library.cells[0].elements.append(.text(text))
        case "text-name": text.string = "wrong"; library.cells[0].elements[textIndex] = .text(text)
        case "text-layer": text.layer = 2; library.cells[0].elements[textIndex] = .text(text)
        case "text-pose": text.transform.angle = 90; library.cells[0].elements[textIndex] = .text(text)
        case "net": text.properties.removeAll { $0.value.hasPrefix("def.pin.netName=") }; text.properties.append(.init(attribute: 0, value: "def.pin.netName=wrong")); library.cells[0].elements[textIndex] = .text(text)
        case "duplicate-property": text.properties.append(text.properties[0]); library.cells[0].elements[textIndex] = .text(text)
        case "crossed-boundary": boundary.points.swapAt(1, 2); library.cells[0].elements[boundaryIndex] = .boundary(boundary)
        case "label": library.cells[0].elements.append(.text(.init(layer: text.layer, texttype: text.texttype, position: text.position, string: text.string)))
        default: Issue.record("Unknown fixture mode"); return
        }
        let bytes = try GDSLibraryWriter.write(library)
        #expect(throws: LayoutIOError.self) { try MaskDataFormatConverter(tech: tech).importFromData(bytes, format: .gds) }
    }
}
