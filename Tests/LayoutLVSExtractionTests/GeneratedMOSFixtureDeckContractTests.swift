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

    @Test
    func fixtureScopeCannotBePromotedThroughSky130ProfileFactory() {
        let fixture = GeneratedMOSFixtureDeck().makeDeck()
        let location = LayoutExtractionSourceLocation(
            path: fixture.sourcePath,
            startLine: 1,
            endLine: 1,
            sourceDigest: fixture.sourceDigest
        )
        let deck = LayoutExtractionDeck(
            processID: "sky130A",
            processProfileID: "fixture.sky130-mos.v1",
            sourcePath: fixture.sourcePath,
            sourceDigest: fixture.sourceDigest,
            qualificationScope: .fixtureOnly,
            deviceRules: [
                LayoutExtractionDeviceRule(
                    ruleID: "fixture.sky130.nmos",
                    family: "mosfet",
                    model: "sky130_fd_pr__nfet_01v8",
                    recognitionExpressions: ["nfet", "nsdm"],
                    parameterExpressions: ["w=w", "l=l"],
                    sourceLocation: location,
                    sourceText: "fixture sky130 nmos"
                ),
                LayoutExtractionDeviceRule(
                    ruleID: "fixture.sky130.pmos",
                    family: "mosfet",
                    model: "sky130_fd_pr__pfet_01v8",
                    recognitionExpressions: ["pfet", "psdm"],
                    parameterExpressions: ["w=w", "l=l"],
                    sourceLocation: location,
                    sourceText: "fixture sky130 pmos"
                ),
            ]
        )

        let profile = Sky130LayoutExtractionProfileFactory().makeProfile(from: deck)

        #expect(profile.mosRules.count == 2)
        #expect(!profile.productionEligible)
    }
}
