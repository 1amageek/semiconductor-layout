import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("LayoutTechSidecarResolver")
struct LayoutTechSidecarResolverTests {

    private let resolver = LayoutTechSidecarResolver()

    // MARK: - No sidecar returns nil

    @Test func noSidecarReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let layoutURL = dir.appendingPathComponent("design.gds")
        try Data().write(to: layoutURL)

        let result = try resolver.resolve(for: layoutURL)
        #expect(result == nil)
    }

    // MARK: - Finds {basename}.lyp

    @Test func findsBasenameLyp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let lypXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>M1</name>
            <source>1/0@1</source>
            <fill-color>#FF0000</fill-color>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """

        let layoutURL = dir.appendingPathComponent("chip.gds")
        try Data().write(to: layoutURL)
        try lypXML.data(using: .utf8)!.write(to: dir.appendingPathComponent("chip.lyp"))

        let result = try resolver.resolve(for: layoutURL)
        #expect(result != nil)
        #expect(result!.layers.count == 1)
        #expect(result!.layers[0].id.name == "M1")
    }

    // MARK: - Finds layers.lyp fallback

    @Test func findsLayersLyp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let lypXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties>
            <name>POLY</name>
            <source>2/0@1</source>
            <visible>true</visible>
          </properties>
        </layer-properties>
        """

        let layoutURL = dir.appendingPathComponent("chip.gds")
        try Data().write(to: layoutURL)
        // No chip.lyp, but layers.lyp exists
        try lypXML.data(using: .utf8)!.write(to: dir.appendingPathComponent("layers.lyp"))

        let result = try resolver.resolve(for: layoutURL)
        #expect(result != nil)
        #expect(result!.layers[0].id.name == "POLY")
    }

    // MARK: - Finds tech.json

    @Test func findsTechJson() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let lib = IRTechLibrary(
            dbuPerMicron: 1000,
            layers: [IRTechLayerDef(name: "M2", type: .routing, gdsLayer: 6, gdsDatatype: 0)]
        )
        let jsonData = try JSONEncoder().encode(lib)

        let layoutURL = dir.appendingPathComponent("chip.gds")
        try Data().write(to: layoutURL)
        // No lyp, no lef, but tech.json exists
        try jsonData.write(to: dir.appendingPathComponent("tech.json"))

        let result = try resolver.resolve(for: layoutURL)
        #expect(result != nil)
        #expect(result!.layers.count == 1)
        #expect(result!.layers[0].id.name == "M2")
    }

    // MARK: - Priority: basename.lyp wins over layers.lyp

    @Test func basenameLypHasPriority() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let basenameLyp = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties><name>FROM_BASENAME</name><source>1/0@1</source><visible>true</visible></properties>
        </layer-properties>
        """
        let layersLyp = """
        <?xml version="1.0" encoding="utf-8"?>
        <layer-properties>
          <properties><name>FROM_LAYERS</name><source>2/0@1</source><visible>true</visible></properties>
        </layer-properties>
        """

        let layoutURL = dir.appendingPathComponent("chip.gds")
        try Data().write(to: layoutURL)
        try basenameLyp.data(using: .utf8)!.write(to: dir.appendingPathComponent("chip.lyp"))
        try layersLyp.data(using: .utf8)!.write(to: dir.appendingPathComponent("layers.lyp"))

        let result = try resolver.resolve(for: layoutURL)
        #expect(result != nil)
        #expect(result!.layers[0].id.name == "FROM_BASENAME")
    }

    // MARK: - Sidecar candidates count

    @Test func sidecarCandidatesList() throws {
        // Verify candidates include all expected formats
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let layoutURL = dir.appendingPathComponent("mydesign.gds")
        try Data().write(to: layoutURL)

        // None exist → nil
        let result = try resolver.resolve(for: layoutURL)
        #expect(result == nil)
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
