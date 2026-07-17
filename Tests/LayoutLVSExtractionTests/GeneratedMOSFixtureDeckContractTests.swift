import Foundation
import LayoutLVSExtraction
import Testing

@Suite("Generated MOS fixture extraction deck contract")
struct GeneratedMOSFixtureDeckContractTests {
    @Test
    func fixtureScopeCannotQualifyForProduction() {
        let deck = GeneratedMOSFixtureDeck().makeDeck()
        let audit = LayoutExtractionDeckAuditor().audit(
            deck,
            requiredFamilies: ["mosfet"]
        )

        #expect(deck.qualificationScope == .fixtureOnly)
        #expect(!deck.qualificationScope.allowsProductionQualification)
        #expect(audit.status == .blocked)
        #expect(!audit.productionEligibility.isEligible)
        #expect(audit.productionEligibility.blockingReasons == [.fixtureOnly])
        #expect(audit.missingRequiredFamilies.isEmpty)
        #expect(audit.unsupportedRequiredFamilies.isEmpty)
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
    func fixtureDeckRoundTripsWithoutLosingQualificationScope() throws {
        let deck = GeneratedMOSFixtureDeck().makeDeck()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(deck)
        let decoded = try JSONDecoder().decode(LayoutExtractionDeck.self, from: data)

        #expect(decoded == deck)
        #expect(decoded.qualificationScope == .fixtureOnly)
        #expect(!decoded.qualificationScope.allowsProductionQualification)
    }

    @Test
    func emptyRequirementSetCannotPromoteFixtureDeck() {
        let audit = LayoutExtractionDeckAuditor().audit(
            GeneratedMOSFixtureDeck().makeDeck(),
            requiredFamilies: []
        )

        #expect(audit.status == .blocked)
        #expect(audit.productionEligibility.blockingReasons == [.fixtureOnly])
    }

}
