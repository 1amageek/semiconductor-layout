import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import Testing

@Suite("Layout constraint validation command", .timeLimit(.minutes(1)))
struct LayoutConstraintValidationCommandTests {
    @Test("CLI service validates analog layout constraints and writes artifacts")
    func validatesConstraintsAndWritesArtifacts() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeTemporaryItem(fixture.rootURL) }

        let response = try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: [
                "--validate-constraints",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--cell-id",
                fixture.cellID.uuidString,
                "--result",
                fixture.resultURL.path,
                "--artifact-manifest",
                fixture.manifestURL.path,
                "--json",
            ])
        )
        let result = try JSONDecoder().decode(
            LayoutConstraintValidationResult.self,
            from: Data(response.output.utf8)
        )

        #expect(response.exitCode == 2)
        #expect(result.status == "failed")
        #expect(result.summary.constraintCount == 1)
        #expect(result.validation.constraintCount == 1)
        #expect(result.validation.errorCount == 1)
        #expect(result.validation.warningCount == 0)
        #expect(result.validation.kindViolationCounts["symmetryPairMismatch"] == 1)
        #expect(result.validation.violations.first?.memberIDs == fixture.memberIDs)
        #expect(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        let manifest = try JSONDecoder().decode(
            LayoutCommandArtifactManifest.self,
            from: Data(contentsOf: fixture.manifestURL)
        )
        #expect(manifest.artifacts.contains { $0.id == "input-layout-document" })
        #expect(manifest.artifacts.contains { $0.id == "layout-constraint-validation-result" })
    }

    @Test("CLI service returns zero when constraint errors are absent")
    func passesWhenConstraintErrorsAreAbsent() throws {
        let fixture = try Self.makePassingFixture()
        defer { Self.removeTemporaryItem(fixture.rootURL) }

        let response = try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: [
                "--validate-constraints",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--json",
            ])
        )
        let result = try JSONDecoder().decode(
            LayoutConstraintValidationResult.self,
            from: Data(response.output.utf8)
        )

        #expect(response.exitCode == 0)
        #expect(result.status == "passed")
        #expect(result.validation.constraintCount == 1)
        #expect(result.validation.violationCount == 0)
    }

    private struct Fixture {
        let rootURL: URL
        let documentURL: URL
        let resultURL: URL
        let manifestURL: URL
        let cellID: UUID
        let memberIDs: [UUID]
    }

    private static func makeFixture() throws -> Fixture {
        let rootURL = try makeRootURL(prefix: "LayoutConstraintValidationCommandTests")
        let documentURL = rootURL.appendingPathComponent("layout.json")
        let resultURL = rootURL.appendingPathComponent("constraints.json")
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let cellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000202"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000203"))
        let document = makeDocument(
            cellID: cellID,
            firstID: firstID,
            secondID: secondID,
            firstOrigin: LayoutPoint(x: 0, y: 0),
            secondOrigin: LayoutPoint(x: 4, y: 1)
        )
        try LayoutDocumentSerializer().encodeDocument(document).write(to: documentURL, options: .atomic)
        return Fixture(
            rootURL: rootURL,
            documentURL: documentURL,
            resultURL: resultURL,
            manifestURL: manifestURL,
            cellID: cellID,
            memberIDs: [firstID, secondID]
        )
    }

    private static func makePassingFixture() throws -> Fixture {
        let rootURL = try makeRootURL(prefix: "LayoutConstraintValidationCommandPassTests")
        let documentURL = rootURL.appendingPathComponent("layout.json")
        let resultURL = rootURL.appendingPathComponent("constraints.json")
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let cellID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000211"))
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000212"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000213"))
        let document = makeDocument(
            cellID: cellID,
            firstID: firstID,
            secondID: secondID,
            firstOrigin: LayoutPoint(x: 0, y: 0),
            secondOrigin: LayoutPoint(x: 4, y: 0)
        )
        try LayoutDocumentSerializer().encodeDocument(document).write(to: documentURL, options: .atomic)
        return Fixture(
            rootURL: rootURL,
            documentURL: documentURL,
            resultURL: resultURL,
            manifestURL: manifestURL,
            cellID: cellID,
            memberIDs: [firstID, secondID]
        )
    }

    private static func makeDocument(
        cellID: UUID,
        firstID: UUID,
        secondID: UUID,
        firstOrigin: LayoutPoint,
        secondOrigin: LayoutPoint
    ) -> LayoutDocument {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let first = LayoutShape(
            id: firstID,
            layer: layer,
            geometry: .rect(LayoutRect(origin: firstOrigin, size: LayoutSize(width: 2, height: 2)))
        )
        let second = LayoutShape(
            id: secondID,
            layer: layer,
            geometry: .rect(LayoutRect(origin: secondOrigin, size: LayoutSize(width: 2, height: 2)))
        )
        let cell = LayoutCell(
            id: cellID,
            name: "DIFFPAIR",
            shapes: [first, second],
            constraints: [
                .symmetry(LayoutSymmetryConstraint(
                    axis: .vertical,
                    members: [firstID, secondID],
                    axisPosition: 3
                )),
            ]
        )
        return LayoutDocument(name: "analog-constraints", cells: [cell], topCellID: cellID)
    }

    private static func makeRootURL(prefix: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
        }
    }
}
