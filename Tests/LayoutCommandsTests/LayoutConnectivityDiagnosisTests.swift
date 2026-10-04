import CircuiteFoundation
import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import Testing

@Suite("Layout connectivity diagnosis CLI", .timeLimit(.minutes(1)))
struct LayoutConnectivityDiagnosisTests {
    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    @Test func serializedRepeatedLocalNetRetainsOccurrencePathsAndPinCounts() throws {
        let local = LayoutNet(name: "local")
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.2), size: .init(width: 0.2, height: 0.2), layer: Self.m1, netID: local.id)
        let child = LayoutCell(name: "CHILD", shapes: [Self.rect(net: local.id, x: 0, y: 0, width: 1, height: 0.4)], pins: [pin], nets: [local])
        let first = LayoutInstance(cellID: child.id, name: "a")
        let second = LayoutInstance(cellID: child.id, name: "b", transform: .init(translation: .init(x: 10, y: 0)))
        let top = LayoutCell(name: "TOP", instances: [first, second])
        let document = LayoutDocument(name: "scoped", cells: [top, child], topCellID: top.id)
        let fixture = try Self.makeFixture(document: document)
        defer { Self.removeTemporaryItem(fixture.directory) }
        let response = try Self.diagnose(fixture: fixture)
        let result = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: response.output)
        #expect(result.schemaVersion == .v3 && result.status == "passed" && response.exitCode == 0)
        #expect(result.diagnosis.sourceDocumentID == document.id && result.diagnosis.nets.count == 2)
        #expect(result.diagnosis.nets.allSatisfy { $0.netID.netID == local.id && $0.pinCount == 1 && !$0.isOpen && $0.name == "local" })
        #expect(Set(result.diagnosis.nets.map(\.netID)).count == 2)
        let paths = result.diagnosis.nets.map { result.diagnosis.occurrences[$0.netID.occurrenceIndex].path }
        #expect(Set(paths.compactMap { $0.first?.instanceID }) == [first.id, second.id])
        for row in result.diagnosis.nets {
            let occurrence = result.diagnosis.occurrences[row.netID.occurrenceIndex]
            #expect(occurrence.sourceCellID == child.id)
            #expect(occurrence.pinRange.count == 1 && result.diagnosis.pins[occurrence.pinRange.lowerBound].id == pin.id)
        }
        let bytes = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(LayoutConnectivityDiagnosisResult.self, from: bytes) == result)

        let parent = LayoutNet(name: "parent")
        var boundDocument = document
        boundDocument.cells[0].nets = [parent]
        boundDocument.cells[0].instances[0].terminalNetIDs = ["P": parent.id]
        boundDocument.cells[0].instances[1].terminalNetIDs = ["P": parent.id]
        let boundFixture = try Self.makeFixture(document: boundDocument)
        defer { Self.removeTemporaryItem(boundFixture.directory) }
        let boundResponse = try Self.diagnose(fixture: boundFixture)
        let bound = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: boundResponse.output)
        #expect(boundResponse.exitCode == 2 && bound.diagnosis.nets.count == 1 && bound.diagnosis.opens.count == 1)
        let row = try #require(bound.diagnosis.nets.first)
        #expect(row.netID.netID == parent.id && row.name == "parent" && row.pinCount == 2 && row.isOpen)
        #expect(bound.diagnosis.occurrences[row.netID.occurrenceIndex].sourceCellID == top.id)
        #expect(bound.diagnosis.occurrences.filter { $0.parentIndex != nil }.allSatisfy { $0.terminalNetIDs["P"] == parent.id })
    }

    @Test func serializedIsolatedPinFailsWithOwnedSourceAndOccurrence() throws {
        let net = LayoutNet(name: "isolated")
        let pin = LayoutPin(name: "P", position: .zero, size: .init(width: 0.2, height: 0.2), layer: Self.m1, netID: net.id)
        let child = LayoutCell(name: "CHILD", pins: [pin], nets: [net])
        let instance = LayoutInstance(cellID: child.id, name: "orphan")
        let top = LayoutCell(name: "TOP", instances: [instance])
        let fixture = try Self.makeFixture(document: .init(name: "pin", cells: [top, child], topCellID: top.id))
        defer { Self.removeTemporaryItem(fixture.directory) }
        let response = try Self.diagnose(fixture: fixture)
        let result = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: response.output)
        #expect(response.exitCode == 2 && result.status == "failed" && result.diagnosis.totals.openCount == 1)
        let open = try #require(result.diagnosis.opens.first), row = try #require(result.diagnosis.nets.first)
        #expect(open.netID == row.netID && row.isOpen && row.islandCount == 0 && row.pinCount == 1)
        #expect(open.islands.isEmpty && open.flylines.isEmpty && open.unconnectedPinIndices.count == 1)
        let occurrence = result.diagnosis.occurrences[open.netID.occurrenceIndex]
        let index = try #require(open.unconnectedPinIndices.first)
        #expect(occurrence.path.first?.instanceID == instance.id && occurrence.pinRange.contains(index))
        #expect(result.diagnosis.pins[index].id == pin.id && open.netID.netID == net.id)
    }

    @Test("Fully connected document exits 0 with zero opens and shorts")
    func fullyConnectedDocumentPasses() throws {
        let net = LayoutNet(name: "sig")
        let fixture = try Self.makeFixture(document: Self.document(
            nets: [net],
            shapes: [
                Self.rect(net: net.id, x: 0, y: 0, width: 1, height: 0.4),
                Self.rect(net: net.id, x: 0.8, y: 0, width: 1, height: 0.4),
            ]
        ))
        defer { Self.removeTemporaryItem(fixture.directory) }

        let response = try Self.diagnose(fixture: fixture)
        let result = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: response.output)

        #expect(response.exitCode == 0)
        #expect(result.status == "passed")
        #expect(result.inputArtifact.format == .json)
        #expect(result.diagnosis.totals.netCount == 1)
        #expect(result.diagnosis.totals.openCount == 0)
        #expect(result.diagnosis.totals.shortCount == 0)
        #expect(result.diagnosis.opens.isEmpty)
        #expect(result.diagnosis.shorts.isEmpty)
        let row = try #require(result.diagnosis.nets.first)
        #expect(row.netID.netID == net.id)
        #expect(row.name == "sig")
        #expect(row.islandCount == 1)
        #expect(!row.isOpen)
        #expect(row.footprintCount == 2)
    }

    @Test("Open net exits 2 and reports flylines and island footprints")
    func openNetReportsFlylinesAndIslands() throws {
        let net = LayoutNet(name: "broken")
        let leftRect = LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 1, height: 0.4)
        )
        let rightRect = LayoutRect(
            origin: LayoutPoint(x: 3, y: 0),
            size: LayoutSize(width: 1, height: 0.4)
        )
        let fixture = try Self.makeFixture(document: Self.document(
            nets: [net],
            shapes: [
                LayoutShape(layer: Self.m1, netID: net.id, geometry: .rect(leftRect)),
                LayoutShape(layer: Self.m1, netID: net.id, geometry: .rect(rightRect)),
            ]
        ))
        defer { Self.removeTemporaryItem(fixture.directory) }

        let response = try Self.diagnose(fixture: fixture)
        let result = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: response.output)

        #expect(response.exitCode == 2)
        #expect(result.status == "failed")
        #expect(result.diagnosis.totals.openCount == 1)
        let row = try #require(result.diagnosis.nets.first { $0.netID.netID == net.id })
        #expect(row.isOpen)
        #expect(row.islandCount == 2)

        let open = try #require(result.diagnosis.opens.first)
        #expect(open.netID.netID == net.id)
        #expect(open.name == "broken")
        #expect(open.islands.count == 2)
        let islandBoxes = Set(open.islands.flatMap { island in
            island.footprints.map(\.boundingBox)
        })
        #expect(islandBoxes == [leftRect, rightRect])
        #expect(open.islands.allSatisfy { island in
            island.footprints.allSatisfy { $0.layer == Self.m1 }
        })

        // Island order is canonical (by member identity), not spatial, so the
        // flyline endpoints may come in either direction.
        let flyline = try #require(open.flylines.first)
        #expect(open.flylines.count == 1)
        #expect(flyline.length == 2)
        #expect(Set([flyline.start, flyline.end]) == [
            LayoutPoint(x: 1, y: 0.2),
            LayoutPoint(x: 3, y: 0.2),
        ])
        #expect(flyline.startLayers == [Self.m1])
        #expect(flyline.endLayers == [Self.m1])
    }

    @Test("Shorted nets are reported with both net identities")
    func shortedNetsAreReported() throws {
        let netA = LayoutNet(name: "a")
        let netB = LayoutNet(name: "b")
        let fixture = try Self.makeFixture(document: Self.document(
            nets: [netA, netB],
            shapes: [
                Self.rect(net: netA.id, x: 0, y: 0, width: 1, height: 0.4),
                Self.rect(net: netB.id, x: 0.5, y: 0, width: 1, height: 0.4),
            ]
        ))
        defer { Self.removeTemporaryItem(fixture.directory) }

        let response = try Self.diagnose(fixture: fixture)
        let result = try Self.decodeJSON(LayoutConnectivityDiagnosisResult.self, from: response.output)

        #expect(response.exitCode == 2)
        #expect(result.status == "failed")
        #expect(result.diagnosis.totals.shortCount == 1)
        let short = try #require(result.diagnosis.shorts.first)
        #expect(Set(short.nets.map { $0.netID.netID }) == [netA.id, netB.id])
        #expect(Set(short.nets.compactMap(\.name)) == ["a", "b"])
        #expect(short.shapeCount == 2)
    }

    @Test("Unreadable input produces a structured failure")
    func unreadableInputProducesStructuredFailure() throws {
        let directory = try Self.makeTemporaryDirectory(prefix: "layout-cli-diagnose-missing")
        defer { Self.removeTemporaryItem(directory) }
        let missingURL = directory.appendingPathComponent("does-not-exist.json")
        let techURL = directory.appendingPathComponent("tech.json")
        try LayoutDocumentSerializer().encodeTech(LayoutTechDatabase.standard())
            .write(to: techURL, options: .atomic)

        var thrown: (any Error)?
        do {
            _ = try LayoutCommandCLIService().runWithExitStatus(
                options: LayoutCommandCLIOptions(arguments: [
                    "--diagnose-connectivity",
                    "--input", missingURL.path,
                    "--input-format", "json",
                    "--tech", techURL.path,
                    "--json",
                ])
            )
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        let failure = try Self.decodeJSON(
            LayoutCommandFailureOutput.self,
            from: LayoutCommandFailureRenderer().jsonString(for: error)
        )
        #expect(failure.status == "failed")
        #expect(failure.errorCode == "layout_command_failed")
        #expect(!failure.message.isEmpty)
    }

    @Test("Diagnosis requires a technology profile even for JSON input")
    func requiresTechnologyForJSONInput() throws {
        let net = LayoutNet(name: "sig")
        let fixture = try Self.makeFixture(document: Self.document(
            nets: [net],
            shapes: [Self.rect(net: net.id, x: 0, y: 0, width: 1, height: 0.4)]
        ))
        defer { Self.removeTemporaryItem(fixture.directory) }

        #expect(throws: LayoutCommandError.missingRequiredArgument("--tech")) {
            _ = try LayoutCommandCLIService().runWithExitStatus(
                options: LayoutCommandCLIOptions(arguments: [
                    "--diagnose-connectivity",
                    "--input", fixture.documentURL.path,
                    "--input-format", "json",
                    "--json",
                ])
            )
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let directory: URL
        let documentURL: URL
        let techURL: URL
    }

    private static func diagnose(fixture: Fixture) throws -> (output: String, exitCode: Int32) {
        try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: [
                "--diagnose-connectivity",
                "--input", fixture.documentURL.path,
                "--input-format", "json",
                "--tech", fixture.techURL.path,
                "--json",
            ])
        )
    }

    private static func makeFixture(document: LayoutDocument) throws -> Fixture {
        let directory = try makeTemporaryDirectory(prefix: "layout-cli-diagnose")
        let documentURL = directory.appendingPathComponent("layout.json")
        let techURL = directory.appendingPathComponent("tech.json")
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(document).write(to: documentURL, options: .atomic)
        try serializer.encodeTech(LayoutTechDatabase.standard()).write(to: techURL, options: .atomic)
        return Fixture(directory: directory, documentURL: documentURL, techURL: techURL)
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func document(nets: [LayoutNet], shapes: [LayoutShape]) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes, nets: nets)
        return LayoutDocument(name: "diagnosis-fixture", cells: [cell], topCellID: cell.id)
    }

    private static func rect(
        net: UUID?,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> LayoutShape {
        LayoutShape(
            layer: m1,
            netID: net,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: width, height: height)
            ))
        )
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(output.utf8))
    }

    private static func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
