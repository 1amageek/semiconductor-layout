import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("TechFormatConverter")
struct TechFormatConverterTests {

    private let converter = TechFormatConverter()

    // MARK: - .lyp loading

    @Test func loadLypFile() throws {
        let lypXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>ACTIVE</name>
            <source>1/0@1</source>
            <frame-color>#1F7A1F</frame-color>
            <fill-color>#41B643</fill-color>
            <dither-pattern>solid</dither-pattern>
            <visible>true</visible>
          </properties>
          <properties>
            <name>POLY</name>
            <source>2/0@1</source>
            <frame-color>#A11111</frame-color>
            <fill-color>#D64545</fill-color>
            <dither-pattern>diag</dither-pattern>
            <visible>true</visible>
          </properties>
          <properties>
            <name>CONT</name>
            <source>4/0@1</source>
            <frame-color>#555555</frame-color>
            <fill-color>#888888</fill-color>
            <dither-pattern>crosshatch</dither-pattern>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_tech.lyp")
        try lypXML.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let tech = try converter.loadTech(from: tempURL)

        #expect(tech.layers.count == 3)
        #expect(tech.layers[0].id.name == "ACTIVE")
        #expect(tech.layers[0].gdsLayer == 1)
        #expect(tech.layers[0].fillPattern == .solid)
        #expect(tech.layers[1].id.name == "POLY")
        #expect(tech.layers[1].gdsLayer == 2)
        #expect(tech.layers[1].fillPattern == .forwardDiagonal)
        #expect(tech.layers[2].id.name == "CONT")
        #expect(tech.layers[2].id.purpose == "cut")
    }

    // MARK: - .json loading

    @Test func loadJsonFile() throws {
        let lib = IRTechLibrary(
            name: "json_test",
            dbuPerMicron: 1000,
            layers: [
                IRTechLayerDef(name: "M1", type: .routing, gdsLayer: 10, gdsDatatype: 0)
            ]
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_tech.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(lib).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let tech = try converter.loadTech(from: tempURL)

        #expect(tech.layers.count == 1)
        #expect(tech.layers[0].id.name == "M1")
        #expect(tech.layers[0].gdsLayer == 10)
        #expect(tech.units.dbuPerMicron == 1000)
    }

    // MARK: - .json save + reload

    @Test func saveAndReloadJSON() throws {
        let lib = IRTechLibrary(
            name: "roundtrip",
            dbuPerMicron: 2000,
            layers: [
                IRTechLayerDef(
                    name: "M1",
                    type: .routing,
                    gdsLayer: 3,
                    gdsDatatype: 0,
                    direction: .horizontal,
                    color: IRTechColor(red: 0.1, green: 0.2, blue: 0.3)
                )
            ],
            vias: [
                IRTechViaDef(
                    name: "VIA1",
                    cutLayerName: "V1",
                    topLayerName: "M2",
                    bottomLayerName: "M1",
                    cutWidth: 0.1,
                    cutHeight: 0.1
                )
            ]
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("save_test.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try converter.saveTechAsJSON(lib, to: tempURL)

        let reloaded = try converter.loadIRTech(from: tempURL)
        #expect(reloaded == lib)
    }

    // MARK: - Unsupported format

    @Test func unsupportedFormat() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.xyz")
        try! "data".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(throws: LayoutIOError.self) {
            try converter.loadTech(from: tempURL)
        }
    }

    // MARK: - Missing file

    @Test func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent.lyp")

        #expect(throws: LayoutIOError.self) {
            try converter.loadTech(from: url)
        }
    }

    // MARK: - IRTech intermediate output

    @Test func loadIRTechFromLyp() throws {
        let lypXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>M1</name>
            <source>10/0@1</source>
            <fill-color>#4A78D1</fill-color>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ir_test.lyp")
        try lypXML.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let irLib = try converter.loadIRTech(from: tempURL)

        #expect(irLib.layers.count == 1)
        #expect(irLib.layers[0].name == "M1")
        #expect(irLib.layers[0].type == .routing)
        #expect(irLib.layers[0].gdsLayer == 10)
        #expect(irLib.metadata["source.format"] == "lyp")
    }
}
