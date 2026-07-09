import Foundation
import LayoutAutoGen
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutTech
import Testing

@Suite("Layout guard-ring command", .timeLimit(.minutes(1)))
struct LayoutGuardRingCommandTests {
    @Test func runnerAddsGuardRingAndWritesReportArtifact() throws {
        let rootURL = try makeRootURL()
        defer { removeTemporaryItem(rootURL) }

        let serializer = LayoutDocumentSerializer()
        let techURL = rootURL.appendingPathComponent("tech.json")
        try serializer.encodeTech(LayoutTechDatabase.sampleProcess()).write(to: techURL, options: .atomic)

        let documentID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000401"))
        let cellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000402"))
        let netID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000403"))
        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "guard-ring-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "vss")),
                .addGuardRing(AddGuardRingCommand(
                    cellID: cellID,
                    technologyPath: techURL.path,
                    request: GuardRingRequest(
                        innerRect: LayoutRect(
                            origin: LayoutPoint(x: 0, y: 0),
                            size: LayoutSize(width: 8, height: 4)
                        ),
                        implantLayer: LayoutLayerID(name: "PIMP", purpose: "drawing"),
                        netID: netID,
                        idSeed: "top-guard-ring"
                    ),
                    reportPath: "artifacts/guard-ring.json"
                )),
            ]
        )

        let result = try LayoutCommandRunner().run(request: request, baseURL: rootURL)

        #expect(result.status == "passed")
        #expect(result.commandCount == 3)
        #expect(result.shapeCount == 12)
        #expect(result.viaCount > 0)
        let documentData = try Data(contentsOf: rootURL.appendingPathComponent("artifacts/layout.json"))
        let document = try serializer.decodeDocument(documentData)
        let cell = try #require(document.cell(withID: cellID))
        #expect(cell.shapes.allSatisfy { $0.properties["analogRole"] == "guardRing" })
        #expect(cell.vias.allSatisfy { $0.viaDefinitionID == "CONT_ACTIVE" && $0.netID == netID })

        let reportURL = rootURL.appendingPathComponent("artifacts/guard-ring.json")
        let report = try JSONDecoder().decode(
            GuardRingGenerationResult.self,
            from: Data(contentsOf: reportURL)
        )
        #expect(report.status == "generated")
        #expect(report.shapeCount == cell.shapes.count)
        #expect(report.viaCount == cell.vias.count)
        #expect(report.contactCount > 0)

        let manifest = try JSONDecoder().decode(
            LayoutCommandArtifactManifest.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("artifacts/manifest.json"))
        )
        #expect(manifest.artifacts.contains { $0.id == "layout-guard-ring-2" })
    }

    private func makeRootURL() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutGuardRingCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path): \(error)")
        }
    }
}
