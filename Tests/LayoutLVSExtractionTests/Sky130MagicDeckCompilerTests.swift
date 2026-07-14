import Foundation
import Testing
import LayoutLVSExtraction

@Suite("Sky130 Magic extraction deck compiler")
struct Sky130MagicDeckCompilerTests {
    @Test func compilesSourceLinkedDeviceRulesAndDigest() throws {
        let sourceURL = try writeDeck(
            """
            tech
            extract
              device mosfet sky130_fd_pr__nfet_01v8 nfet ndiff pwell
              device resistor sky130_fd_pr__res_generic_m1 rmetal1 metal1
              device capacitor sky130_fd_pr__cap_mim_m3_1 mimcap m3 1
            end
            """
        )

        let deck = try Sky130MagicDeckCompiler().compile(sourceURL: sourceURL)

        #expect(deck.processID == "sky130A")
        #expect(deck.processProfileID == "sky130.open-pdk.digital-mos.signoff")
        #expect(deck.sourceDigest.count == 64)
        #expect(deck.deviceRules.count == 3)
        #expect(Set(deck.deviceRules.map(\.family)) == Set(["mosfet", "resistor", "capacitor"]))
        #expect(deck.deviceRules.allSatisfy {
            $0.sourceLocation.sourceDigest == deck.sourceDigest
                && $0.sourceLocation.path == sourceURL.path(percentEncoded: false)
        })
    }

    @Test func continuationLinesRetainSourceRange() throws {
        let sourceURL = try writeDeck(
            """
            extract
              device mosfet sky130_fd_pr__nfet_01v8 nfet \\
                ndiff pwell l=l w=w
            end
            """
        )

        let deck = try Sky130MagicDeckCompiler().compile(sourceURL: sourceURL)
        let rule = try #require(deck.deviceRules.first)

        #expect(rule.sourceLocation.startLine == 2)
        #expect(rule.sourceLocation.endLine == 3)
        #expect(rule.parameterExpressions == ["l=l", "w=w"])
    }

    @Test func completenessAuditBlocksMissingOrUnsupportedSemantics() throws {
        let sourceURL = try writeDeck(
            """
            extract
              device mosfet sky130_fd_pr__nfet_01v8 nfet ndiff pwell
              device unknown custom_model layer_a layer_b
            end
            """
        )
        let deck = try Sky130MagicDeckCompiler().compile(sourceURL: sourceURL)

        let audit = LayoutExtractionDeckAuditor().audit(
            deck,
            requiredFamilies: ["mosfet", "resistor"]
        )

        #expect(audit.status == .blocked)
        #expect(audit.missingRequiredFamilies == ["resistor"])
        #expect(audit.unsupportedDirectiveCount == 1)
        #expect(audit.unsupportedRequiredFamilies.isEmpty)
        #expect(audit.productionEligibility.blockingReasons.contains(
            .missingRequiredFamily("resistor")
        ))
        #expect(!audit.productionEligibility.blockingReasons.contains(
            .unsupportedDirective(reasonCode: "unsupported-device-family")
        ))
    }

    @Test func requiredFamilyRemainsBlockedWhenOneOfItsSemanticsIsUnsupported() throws {
        let sourceURL = try writeDeck(
            """
            extract
              device mosfet sky130_fd_pr__nfet_01v8 nfet ndiff pwell
              device mosfet Ignore unsupported_selector pwell
            end
            """
        )
        let deck = try Sky130MagicDeckCompiler().compile(sourceURL: sourceURL)

        let audit = LayoutExtractionDeckAuditor().audit(
            deck,
            requiredFamilies: ["mosfet"]
        )

        #expect(audit.deviceRuleCountsByFamily["mosfet"] == 1)
        #expect(audit.missingRequiredFamilies.isEmpty)
        #expect(audit.unsupportedRequiredFamilies == ["mosfet"])
        #expect(audit.status == .blocked)
        #expect(!audit.productionEligibility.isEligible)
        #expect(audit.productionEligibility.blockingReasons == [
            .unsupportedRequiredFamily(
                family: "mosfet",
                reasonCode: "ignored-device-rule"
            ),
        ])
        let unsupported = try #require(deck.unsupportedDirectives.first)
        #expect(unsupported.family == "mosfet")
        #expect(unsupported.sourceLocation.startLine == 3)
        #expect(unsupported.sourceLocation.sourceDigest == deck.sourceDigest)
    }

    @Test func supportedProductionCandidateIsEligible() throws {
        let sourceURL = try writeDeck(
            """
            extract
              device mosfet sky130_fd_pr__nfet_01v8 nfet ndiff pwell
              device resistor sky130_fd_pr__res_generic_m1 rmetal1 metal1
            end
            """
        )
        let deck = try Sky130MagicDeckCompiler().compile(sourceURL: sourceURL)

        let audit = LayoutExtractionDeckAuditor().audit(
            deck,
            requiredFamilies: ["mosfet", "resistor"]
        )

        #expect(deck.qualificationScope == .productionCandidate)
        #expect(deck.qualificationScope.allowsProductionQualification)
        #expect(audit.status == .satisfied)
        #expect(audit.productionEligibility.isEligible)
        #expect(audit.productionEligibility.blockingReasons.isEmpty)
    }

    private func writeDeck(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "layout-extraction-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "sky130A.tech")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
