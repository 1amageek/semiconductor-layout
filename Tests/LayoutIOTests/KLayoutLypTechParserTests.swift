import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("KLayoutLypTechParser")
struct KLayoutLypTechParserTests {

    private let parser = KLayoutLypTechParser()

    private let nandFlashLyp = """
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
        <name>M1</name>
        <source>3/0@1</source>
        <frame-color>#1F3F8A</frame-color>
        <fill-color>#4A78D1</fill-color>
        <dither-pattern>forwardDiagonal</dither-pattern>
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
      <properties>
        <name>VIA1</name>
        <source>7/0@1</source>
        <frame-color>#888809</frame-color>
        <fill-color>#DBDB2C</fill-color>
        <dither-pattern>crosshatch</dither-pattern>
        <visible>true</visible>
      </properties>
    </layer-properties>
    """

    // MARK: - parseToIRTech

    @Test func parseToIRTech() throws {
        let data = nandFlashLyp.data(using: .utf8)!
        let lib = try parser.parseToIRTech(data: data)

        #expect(lib.layers.count == 5)
        #expect(lib.dbuPerMicron == 1000)
        #expect(lib.metadata["source.format"] == "lyp")

        // Sorted by gdsLayer
        #expect(lib.layers[0].name == "ACTIVE")
        #expect(lib.layers[0].gdsLayer == 1)
        #expect(lib.layers[0].gdsDatatype == 0)
        #expect(lib.layers[0].type == .routing)
        #expect(lib.layers[0].fillPattern == .solid)
        #expect(lib.layers[0].visibleByDefault == true)

        #expect(lib.layers[1].name == "POLY")
        #expect(lib.layers[1].gdsLayer == 2)
        #expect(lib.layers[1].fillPattern == .forwardDiagonal)

        #expect(lib.layers[2].name == "M1")
        #expect(lib.layers[2].gdsLayer == 3)

        // CONT has "contact" → cut type
        #expect(lib.layers[3].name == "CONT")
        #expect(lib.layers[3].gdsLayer == 4)
        #expect(lib.layers[3].type == .cut)

        // VIA1 has "via" → cut type
        #expect(lib.layers[4].name == "VIA1")
        #expect(lib.layers[4].gdsLayer == 7)
        #expect(lib.layers[4].type == .cut)
    }

    @Test func parseToIRTechColors() throws {
        let data = nandFlashLyp.data(using: .utf8)!
        let lib = try parser.parseToIRTech(data: data)

        // ACTIVE fill-color is #41B643
        let activeColor = lib.layers[0].color!
        #expect(abs(activeColor.red - 0.255) < 0.01)
        #expect(abs(activeColor.green - 0.714) < 0.01)
        #expect(abs(activeColor.blue - 0.263) < 0.01)
        #expect(activeColor.alpha == 1.0)
    }

    @Test func parseToIRTechEmptyInput() {
        let data = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
        </layer-properties>
        """.data(using: .utf8)!

        #expect(throws: LayoutIOError.self) {
            try parser.parseToIRTech(data: data)
        }
    }

    @Test func parseToIRTechInvalidXML() {
        let data = "not xml at all".data(using: .utf8)!

        #expect(throws: LayoutIOError.self) {
            try parser.parseToIRTech(data: data)
        }
    }

    // MARK: - Source with no @ suffix

    @Test func sourceWithoutAtSuffix() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>TEST</name>
            <source>42/5</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let data = xml.data(using: .utf8)!
        let lib = try parser.parseToIRTech(data: data)

        #expect(lib.layers.count == 1)
        #expect(lib.layers[0].gdsLayer == 42)
        #expect(lib.layers[0].gdsDatatype == 5)
    }

    // MARK: - Duplicate names get unique IDs

    @Test func duplicateNamesGetUniqueIDs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>M1</name>
            <source>1/0@1</source>
            <visible>true</visible>
          </properties>
          <properties>
            <name>M1</name>
            <source>1/1@1</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let data = xml.data(using: .utf8)!
        let lib = try parser.parseToIRTech(data: data)

        #expect(lib.layers.count == 2)
        #expect(lib.layers[0].name != lib.layers[1].name)
    }
}
