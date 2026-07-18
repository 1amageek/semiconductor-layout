import CryptoKit
import Foundation
import LayoutLVSExtraction
import Testing

@Suite struct LayoutExtractionProcessProfileLoaderTests {
    @Test func loadsProfileWhenDeckDigestAndIdentityMatch() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        let profile = try LayoutExtractionProcessProfileLoader().load(
            profileURL: fixture.profileURL,
            extractionDeckURL: fixture.deckURL,
            expectedProcessProfileID: "test.profile"
        )

        #expect(profile.processID == "test-process")
        #expect(profile.processProfileID == "test.profile")
        #expect(profile.deckUseScope == .processProvided)

        let data = try Data(contentsOf: fixture.profileURL)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["deckUseScope"] as? String == "processProvided")
        #expect(object["productionEligible"] == nil)
    }

    @Test func rejectsMissingProfileArtifact() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        let missingURL = fixture.root.appending(path: "missing-profile.json")

        #expect(throws: LayoutExtractionProcessProfileError.self) {
            _ = try LayoutExtractionProcessProfileLoader().load(
                profileURL: missingURL,
                extractionDeckURL: fixture.deckURL,
                expectedProcessProfileID: nil
            )
        }
    }

    @Test func rejectsMalformedProfileArtifact() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try Data("not-json".utf8).write(to: fixture.profileURL, options: [.atomic])

        #expect(throws: LayoutExtractionProcessProfileError.self) {
            _ = try LayoutExtractionProcessProfileLoader().load(
                profileURL: fixture.profileURL,
                extractionDeckURL: fixture.deckURL,
                expectedProcessProfileID: nil
            )
        }
    }

    @Test func rejectsProcessProfileIdentityMismatch() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }

        #expect(throws: LayoutExtractionProcessProfileError.processProfileMismatch(
            expected: "different.profile",
            actual: "test.profile"
        )) {
            _ = try LayoutExtractionProcessProfileLoader().load(
                profileURL: fixture.profileURL,
                extractionDeckURL: fixture.deckURL,
                expectedProcessProfileID: "different.profile"
            )
        }
    }

    @Test func rejectsExtractionDeckDigestMismatch() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.root) }
        try Data("modified-deck".utf8).write(to: fixture.deckURL, options: [.atomic])

        #expect(throws: LayoutExtractionProcessProfileError.self) {
            _ = try LayoutExtractionProcessProfileLoader().load(
                profileURL: fixture.profileURL,
                extractionDeckURL: fixture.deckURL,
                expectedProcessProfileID: nil
            )
        }
    }

    @Test func rejectsUnsupportedSchemaVersion() throws {
        let fixture = try makeFixture(schemaVersion: 3)
        defer { remove(fixture.root) }

        #expect(throws: LayoutExtractionProcessProfileError.unsupportedSchemaVersion(
            actual: 3,
            supported: 2
        )) {
            _ = try LayoutExtractionProcessProfileLoader().load(
                profileURL: fixture.profileURL,
                extractionDeckURL: fixture.deckURL,
                expectedProcessProfileID: nil
            )
        }
    }

    private func makeFixture(
        schemaVersion: Int = LayoutExtractionProcessProfile.currentSchemaVersion
    ) throws -> (
        root: URL,
        profileURL: URL,
        deckURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "layout-extraction-profile-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deckURL = root.appending(path: "extraction.deck")
        let deckData = Data("process-owned-extraction-deck".utf8)
        try deckData.write(to: deckURL, options: [.atomic])
        let digest = SHA256.hash(data: deckData)
            .map { String(format: "%02x", $0) }
            .joined()
        let profile = LayoutExtractionProcessProfile(
            schemaVersion: schemaVersion,
            processID: "test-process",
            processProfileID: "test.profile",
            extractionDeckDigest: digest,
            deckUseScope: .processProvided,
            conductorLayers: LayoutExtractionLayerReference(names: ["active", "poly", "metal1"]),
            connectionRules: [],
            mosRules: [
                LayoutExtractionMOSRule(
                    ruleID: "nmos",
                    model: "nmos",
                    gateLayers: LayoutExtractionLayerReference(names: ["poly"]),
                    diffusionLayers: LayoutExtractionLayerReference(names: ["active"]),
                    selectorLayers: LayoutExtractionLayerReference(names: ["nimplant"]),
                    bulkLayers: LayoutExtractionLayerReference(names: ["substrate"]),
                    bulkPortCandidates: ["VSS"]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let profileURL = root.appending(path: "extraction-profile.json")
        try encoder.encode(profile).write(to: profileURL, options: [.atomic])
        return (root, profileURL, deckURL)
    }

    private func remove(_ root: URL) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Could not remove test fixture: \(error.localizedDescription)")
        }
    }
}
