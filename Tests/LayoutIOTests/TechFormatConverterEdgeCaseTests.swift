import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
import LEF
@testable import LayoutIO

@Suite("TechFormatConverter Edge Cases")
struct TechFormatConverterEdgeCaseTests {

    private let converter = TechFormatConverter()

    // MARK: - .lef loading

    @Test func loadLefFile() throws {
        let lefText = """
        VERSION 5.8 ;
        UNITS
            DATABASE MICRONS 2000 ;
        END UNITS
        LAYER POLY
            TYPE MASTERSLICE ;
        END POLY
        LAYER M1
            TYPE ROUTING ;
            DIRECTION HORIZONTAL ;
            PITCH 0.28 ;
            WIDTH 0.14 ;
            SPACING 0.14 ;
        END M1
        LAYER VIA1
            TYPE CUT ;
            SPACING 0.17 ;
        END VIA1
        END LIBRARY
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_tech.lef")
        try lefText.data(using: .utf8)!.write(to: tempURL)
        defer { removeTemporaryItem(tempURL) }

        let tech = try converter.loadTech(from: tempURL)

        #expect(tech.layers.count == 3)
        #expect(tech.units.dbuPerMicron == 2000)
        #expect(tech.layers[0].id.name == "POLY")
        #expect(tech.layers[1].id.name == "M1")
        #expect(tech.layers[1].preferredDirection == .horizontal)
        #expect(tech.layers[2].id.name == "VIA1")
        #expect(tech.layers[2].id.purpose == "cut")
    }

    // MARK: - .lef IR intermediate output

    @Test func loadIRTechFromLef() throws {
        let lefText = """
        VERSION 5.8 ;
        UNITS
            DATABASE MICRONS 1000 ;
        END UNITS
        LAYER M1
            TYPE ROUTING ;
            DIRECTION VERTICAL ;
            WIDTH 0.1 ;
        END M1
        END LIBRARY
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ir_test.lef")
        try lefText.data(using: .utf8)!.write(to: tempURL)
        defer { removeTemporaryItem(tempURL) }

        let irLib = try converter.loadIRTech(from: tempURL)

        #expect(irLib.layers.count == 1)
        #expect(irLib.layers[0].name == "M1")
        #expect(irLib.layers[0].type == .routing)
        #expect(irLib.layers[0].direction == .vertical)
        #expect(irLib.metadata["lef.version"] == "5.8")
    }

    // MARK: - Invalid JSON content

    @Test func invalidJsonContent() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad.json")
        try "{ invalid json }".data(using: .utf8)!.write(to: tempURL)
        defer { removeTemporaryItem(tempURL) }

        #expect(throws: LayoutIOError.self) {
            try converter.loadTech(from: tempURL)
        }
    }

    // MARK: - End-to-end: lyp → IRTech → JSON → reload

    @Test func endToEndLypToJsonRoundTrip() throws {
        let lypXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>ACTIVE</name>
            <source>1/0@1</source>
            <fill-color>#41B643</fill-color>
            <dither-pattern>solid</dither-pattern>
            <visible>true</visible>
          </properties>
          <properties>
            <name>CONT</name>
            <source>4/0@1</source>
            <fill-color>#888888</fill-color>
            <dither-pattern>crosshatch</dither-pattern>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """

        let lypURL = FileManager.default.temporaryDirectory.appendingPathComponent("e2e_test.lyp")
        try lypXML.data(using: .utf8)!.write(to: lypURL)
        defer { removeTemporaryItem(lypURL) }

        // Step 1: Load .lyp → IRTechLibrary
        let irLib = try converter.loadIRTech(from: lypURL)
        #expect(irLib.layers.count == 2)

        // Step 2: Save as JSON
        let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent("e2e_test.json")
        defer { removeTemporaryItem(jsonURL) }
        try converter.saveTechAsJSON(irLib, to: jsonURL)

        // Step 3: Reload from JSON
        let reloaded = try converter.loadIRTech(from: jsonURL)
        #expect(reloaded == irLib)

        // Step 4: Convert to LayoutTechDatabase
        let tech = try converter.loadTech(from: jsonURL)
        #expect(tech.layers.count == 2)
        #expect(tech.layers[0].id.name == "ACTIVE")
        #expect(tech.layers[0].id.purpose == "drawing")
        #expect(tech.layers[1].id.name == "CONT")
        #expect(tech.layers[1].id.purpose == "cut")
    }

    // MARK: - End-to-end: LEF → IRTech → LayoutTechDatabase

    @Test func endToEndLefPipeline() throws {
        let lefText = """
        VERSION 5.8 ;
        UNITS
            DATABASE MICRONS 1000 ;
        END UNITS
        LAYER M1
            TYPE ROUTING ;
            DIRECTION HORIZONTAL ;
            PITCH 0.28 ;
            WIDTH 0.14 ;
            SPACING 0.14 ;
            AREA 0.058 ;
        END M1
        LAYER VIA1
            TYPE CUT ;
            SPACING 0.17 ;
        END VIA1
        LAYER M2
            TYPE ROUTING ;
            DIRECTION VERTICAL ;
            PITCH 0.28 ;
            WIDTH 0.14 ;
            SPACING 0.14 ;
        END M2
        SITE core_site
            CLASS CORE ;
            SYMMETRY Y ;
            SIZE 0.19 BY 1.4 ;
        END core_site
        END LIBRARY
        """

        let lefURL = FileManager.default.temporaryDirectory.appendingPathComponent("e2e_process.lef")
        try lefText.data(using: .utf8)!.write(to: lefURL)
        defer { removeTemporaryItem(lefURL) }

        // Full pipeline: LEF → IRTech → LayoutTechDatabase
        let tech = try converter.loadTech(from: lefURL)

        #expect(tech.layers.count == 3)
        #expect(tech.layers[0].id.name == "M1")
        #expect(tech.layers[0].preferredDirection == .horizontal)
        #expect(tech.layers[1].id.name == "VIA1")
        #expect(tech.layers[1].id.purpose == "cut")
        #expect(tech.layers[2].id.name == "M2")
        #expect(tech.layers[2].preferredDirection == .vertical)

        // Design rules extracted
        let m1Rule = tech.layerRules.first { $0.layerID.name == "M1" }
        #expect(m1Rule != nil)
        #expect(m1Rule?.minWidth == 0.14)
        #expect(m1Rule?.minSpacing == 0.14)
        #expect(m1Rule?.minArea == 0.058)

        #expect(tech.units.dbuPerMicron == 1000)
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
