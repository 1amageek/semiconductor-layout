import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("KLayoutLypTechParser Edge Cases")
struct KLayoutLypTechParserEdgeCaseTests {

    private let parser = KLayoutLypTechParser()

    // MARK: - ARGB 8-digit hex color

    @Test func argb8DigitColor() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>SEMI</name>
            <source>1/0@1</source>
            <fill-color>#80FF0000</fill-color>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let data = xml.data(using: .utf8)!
        let lib = try parser.parseToIRTech(data: data)

        let color = lib.layers[0].color!
        #expect(abs(color.alpha - 0.502) < 0.01) // 0x80 = 128 → 128/255 ≈ 0.502
        #expect(abs(color.red - 1.0) < 0.01)     // 0xFF
        #expect(abs(color.green - 0.0) < 0.01)   // 0x00
        #expect(abs(color.blue - 0.0) < 0.01)    // 0x00
    }

    // MARK: - All pattern strings

    @Test func patternDots() throws {
        let lib = try parseWithPattern("dotted")
        #expect(lib.layers[0].fillPattern == .dots)
    }

    @Test func patternGrid() throws {
        let lib = try parseWithPattern("grid")
        #expect(lib.layers[0].fillPattern == .grid)
    }

    @Test func patternCrosshatch() throws {
        let lib = try parseWithPattern("crosshatch")
        #expect(lib.layers[0].fillPattern == .crosshatch)
    }

    @Test func patternHorizontal() throws {
        let lib = try parseWithPattern("horizontal")
        #expect(lib.layers[0].fillPattern == .horizontal)
    }

    @Test func patternVertical() throws {
        let lib = try parseWithPattern("vertical")
        #expect(lib.layers[0].fillPattern == .vertical)
    }

    @Test func patternBackwardDiagonal() throws {
        let lib = try parseWithPattern("backward_slash")
        #expect(lib.layers[0].fillPattern == .backwardDiagonal)
    }

    @Test func patternForwardSlash() throws {
        let lib = try parseWithPattern("forward_slash")
        #expect(lib.layers[0].fillPattern == .forwardDiagonal)
    }

    @Test func patternSolid() throws {
        let lib = try parseWithPattern("solid")
        #expect(lib.layers[0].fillPattern == .solid)
    }

    @Test func patternUnknownDefaultsSolid() throws {
        let lib = try parseWithPattern("unknown_pattern_xyz")
        #expect(lib.layers[0].fillPattern == .solid)
    }

    @Test func patternNilDefaultsSolid() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>TEST</name>
            <source>1/0@1</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers[0].fillPattern == .solid)
    }

    // MARK: - Source format edge cases

    @Test func sourceWithZeroLayerDatatype() throws {
        let xml = makeLyp(name: "ZERO", source: "0/0@1")
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers[0].gdsLayer == 0)
        #expect(lib.layers[0].gdsDatatype == 0)
    }

    @Test func sourceWithNoAtSuffix() throws {
        let xml = makeLyp(name: "PLAIN", source: "42/5")
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers[0].gdsLayer == 42)
        #expect(lib.layers[0].gdsDatatype == 5)
    }

    @Test func sourceInvalid() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>BAD</name>
            <source>invalid</source>
            <visible>true</visible>
          </properties>
          <properties>
            <name>GOOD</name>
            <source>1/0@1</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        // Invalid source is skipped
        #expect(lib.layers.count == 1)
        #expect(lib.layers[0].name == "GOOD")
    }

    // MARK: - Layer without name gets auto-generated display name

    @Test func layerWithNoName() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <source>5/2@1</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers.count == 1)
        // Auto-generated name from gds layer/datatype
        #expect(lib.layers[0].name.contains("5") || lib.layers[0].name.contains("L5"))
    }

    // MARK: - Visible false

    @Test func visibleFalse() throws {
        let xml = makeLyp(name: "INVIS", source: "1/0", visible: "false")
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers[0].visibleByDefault == false)
    }

    @Test func visibleZero() throws {
        let xml = makeLyp(name: "INVIS", source: "1/0", visible: "0")
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers[0].visibleByDefault == false)
    }

    // MARK: - Sort order by gdsLayer then gdsDatatype

    @Test func sortOrder() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties><name>C</name><source>3/0</source><visible>true</visible></properties>
          <properties><name>A</name><source>1/0</source><visible>true</visible></properties>
          <properties><name>B2</name><source>2/1</source><visible>true</visible></properties>
          <properties><name>B1</name><source>2/0</source><visible>true</visible></properties>
        </layer-properties>
        """
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        #expect(lib.layers.count == 4)
        #expect(lib.layers[0].gdsLayer == 1) // A
        #expect(lib.layers[1].gdsLayer == 2)
        #expect(lib.layers[1].gdsDatatype == 0) // B1
        #expect(lib.layers[2].gdsLayer == 2)
        #expect(lib.layers[2].gdsDatatype == 1) // B2
        #expect(lib.layers[3].gdsLayer == 3) // C
    }

    // MARK: - Fallback color when no color attributes

    @Test func fallbackColor() throws {
        let xml = makeLyp(name: "NOCOLOR", source: "10/0")
        let lib = try parser.parseToIRTech(data: xml.data(using: .utf8)!)
        let color = lib.layers[0].color!
        #expect(color.red >= 0 && color.red <= 1)
        #expect(color.green >= 0 && color.green <= 1)
        #expect(color.blue >= 0 && color.blue <= 1)
        #expect(color.alpha == 1.0)
    }

    // MARK: - Helpers

    private func parseWithPattern(_ pattern: String) throws -> IRTechLibrary {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>TEST</name>
            <source>1/0@1</source>
            <dither-pattern>\(pattern)</dither-pattern>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """
        return try parser.parseToIRTech(data: xml.data(using: .utf8)!)
    }

    private func makeLyp(name: String, source: String, visible: String = "true") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>\(name)</name>
            <source>\(source)</source>
            <visible>\(visible)</visible>
          </properties>
        </layer-properties>
        """
    }
}
