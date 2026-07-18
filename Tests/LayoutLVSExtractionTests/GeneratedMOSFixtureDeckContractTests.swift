import Foundation
import LayoutLVSExtraction
import Testing

@Suite("Generated MOS fixture extraction deck contract")
struct GeneratedMOSFixtureDeckContractTests {
    @Test
    func fixtureScopeDoesNotChangeSemanticReadiness() {
        let deck = GeneratedMOSFixtureDeck().makeDeck()
        let audit = LayoutExtractionDeckAuditor().audit(
            deck,
            requiredFamilies: ["mosfet"]
        )

        #expect(deck.useScope == .fixtureOnly)
        #expect(audit.useScope == .fixtureOnly)
        #expect(audit.semanticReadiness.isReady)
        #expect(audit.isReady)
        #expect(audit.semanticReadiness.issues.isEmpty)
        #expect(audit.missingRequiredFamilies.isEmpty)
        #expect(audit.unsupportedRequiredFamilies.isEmpty)
    }

    @Test
    func useScopeDoesNotChangeSemanticAudit() {
        let fixtureDeck = GeneratedMOSFixtureDeck().makeDeck()
        let processDeck = LayoutExtractionDeck(
            processID: fixtureDeck.processID,
            processProfileID: fixtureDeck.processProfileID,
            sourcePath: fixtureDeck.sourcePath,
            sourceDigest: fixtureDeck.sourceDigest,
            useScope: .processProvided,
            deviceRules: fixtureDeck.deviceRules,
            unsupportedDirectives: fixtureDeck.unsupportedDirectives
        )
        let auditor = LayoutExtractionDeckAuditor()

        let fixtureAudit = auditor.audit(fixtureDeck, requiredFamilies: ["mosfet"])
        let processAudit = auditor.audit(processDeck, requiredFamilies: ["mosfet"])

        #expect(fixtureAudit.useScope == .fixtureOnly)
        #expect(processAudit.useScope == .processProvided)
        #expect(fixtureAudit.semanticReadiness == processAudit.semanticReadiness)
        #expect(processAudit.isReady)
    }

    @Test
    func fixtureDeckIsDeterministicAndSourceLinked() {
        let first = GeneratedMOSFixtureDeck().makeDeck()
        let second = GeneratedMOSFixtureDeck().makeDeck()

        #expect(first == second)
        #expect(first.sourceDigest.count == 64)
        #expect(first.deviceRules.map(\.model) == ["nmos", "pmos"])
        #expect(first.deviceRules.allSatisfy {
            $0.family == "mosfet"
                && $0.sourceLocation.path == first.sourcePath
                && $0.sourceLocation.sourceDigest == first.sourceDigest
        })
        #expect(first.deviceRules.first { $0.model == "nmos" }?.recognitionExpressions == [
            "ACTIVE", "POLY", "NIMP",
        ])
        #expect(first.deviceRules.first { $0.model == "pmos" }?.recognitionExpressions == [
            "ACTIVE", "POLY", "PIMP",
        ])
        #expect(first.deviceRules.allSatisfy {
            $0.parameterExpressions == [
                "w=channelWidth", "l=channelLength", "m=parallelFingerCount",
            ]
        })
    }

    @Test
    func fixtureDeckRoundTripsWithoutLosingUseScope() throws {
        let deck = GeneratedMOSFixtureDeck().makeDeck()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(deck)
        let decoded = try JSONDecoder().decode(LayoutExtractionDeck.self, from: data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(decoded == deck)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.useScope == .fixtureOnly)
        #expect(object["useScope"] as? String == "fixtureOnly")
        #expect(object["qualificationScope"] == nil)
        #expect(object["productionEligible"] == nil)
    }

    @Test
    func versionedFixtureUsesSemanticContract() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "generated-mos-extraction-deck-v2",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: fixtureURL)
        let deck = try JSONDecoder().decode(LayoutExtractionDeck.self, from: data)

        #expect(deck == GeneratedMOSFixtureDeck().makeDeck())
        #expect(deck.schemaVersion == LayoutExtractionDeck.currentSchemaVersion)
        #expect(deck.useScope == .fixtureOnly)
    }

    @Test
    func emptyRequirementSetIsSemanticallyReady() {
        let audit = LayoutExtractionDeckAuditor().audit(
            GeneratedMOSFixtureDeck().makeDeck(),
            requiredFamilies: []
        )

        #expect(audit.useScope == .fixtureOnly)
        #expect(audit.isReady)
        #expect(audit.semanticReadiness.issues.isEmpty)
    }

    @Test
    func missingFamilyProducesSemanticIssue() {
        let audit = LayoutExtractionDeckAuditor().audit(
            GeneratedMOSFixtureDeck().makeDeck(),
            requiredFamilies: ["diode", "mosfet"]
        )

        #expect(!audit.isReady)
        #expect(audit.semanticReadiness.issues == [.missingRequiredFamily("diode")])
    }

}
