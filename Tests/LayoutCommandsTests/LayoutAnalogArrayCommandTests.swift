import CircuiteFoundation
import Foundation
import LayoutAutoGen
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutVerify
import Testing

@Suite("Layout analog-array command", .timeLimit(.minutes(1)))
struct LayoutAnalogArrayCommandTests {
    @Test func runnerPlacesAnalogArrayAndWritesReportArtifact() throws {
        let rootURL = try makeRootURL()
        defer { removeTemporaryItem(rootURL) }

        let documentID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
        let topCellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000602"))
        let unitCellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000603"))
        let shapeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000604"))
        let memberIDs = try (0..<4).map { index in
            try #require(UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", 605 + index))"))
        }
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "analog-array-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: topCellID, name: "top", makeTop: true)),
                .createCell(CreateCellCommand(cellID: unitCellID, name: "unit")),
                .addRect(AddRectCommand(
                    cellID: unitCellID,
                    shapeID: shapeID,
                    layer: layer,
                    origin: .zero,
                    size: LayoutSize(width: 1, height: 2)
                )),
                .addInstance(AddInstanceCommand(
                    cellID: topCellID,
                    instanceID: memberIDs[0],
                    referencedCellID: unitCellID,
                    name: "a0"
                )),
                .addInstance(AddInstanceCommand(
                    cellID: topCellID,
                    instanceID: memberIDs[1],
                    referencedCellID: unitCellID,
                    name: "a1"
                )),
                .addInstance(AddInstanceCommand(
                    cellID: topCellID,
                    instanceID: memberIDs[2],
                    referencedCellID: unitCellID,
                    name: "b0"
                )),
                .addInstance(AddInstanceCommand(
                    cellID: topCellID,
                    instanceID: memberIDs[3],
                    referencedCellID: unitCellID,
                    name: "b1"
                )),
                .placeAnalogArray(PlaceAnalogArrayCommand(
                    cellID: topCellID,
                    request: AnalogArrayPlacementRequest(
                        memberInstanceIDs: memberIDs,
                        pattern: [0, 0, 1, 1],
                        firstSlotCenter: LayoutPoint(x: 0, y: 0),
                        slotPitch: LayoutSize(width: 2, height: 0)
                    ),
                    reportPath: "artifacts/analog-array.json"
                )),
            ]
        )

        let result = try LayoutCommandRunner().run(request: request, baseURL: rootURL)

        #expect(result.status == "passed")
        #expect(result.commandCount == request.commands.count)
        let document = try LayoutDocumentSerializer().decodeDocument(
            Data(contentsOf: rootURL.appendingPathComponent("artifacts/layout.json"))
        )
        let top = try #require(document.cell(withID: topCellID))
        #expect(top.constraints.count == 3)
        let violations = try LayoutConstraintChecker().check(document: document, cellID: topCellID)
        #expect(violations.isEmpty, "placed analog array constraints should be clean, got \(violations)")

        let report = try JSONDecoder().decode(
            AnalogArrayPlacementResult.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("artifacts/analog-array.json"))
        )
        #expect(report.slotLabels == [0, 1, 1, 0])
        #expect(report.arrangedMemberInstanceIDs == [memberIDs[0], memberIDs[2], memberIDs[3], memberIDs[1]])

        let manifest = try JSONDecoder().decode(
            EvidenceManifest.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("artifacts/manifest.json"))
        )
        #expect(manifest.artifacts.contains { $0.locator.role.rawValue == "layout-analog-array-7" })
    }

    private func makeRootURL() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutAnalogArrayCommandTests-\(UUID().uuidString)", isDirectory: true)
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
