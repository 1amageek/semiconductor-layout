import Foundation
import Testing
import LayoutTech

@Suite("Layout rule program")
struct LayoutRuleProgramTests {
    @Test func programDigestAndCoverageAreDeterministic() throws {
        let first = LayoutRuleProgram(
            programID: "sky130A",
            compilerVersion: "compiler-1",
            sourceDeckDigest: "deck-sha",
            nodes: [
                LayoutRuleProgramNode(nodeID: "n2", operation: "spacing", inputLayerIDs: ["M2", "M1"]),
                LayoutRuleProgramNode(nodeID: "n1", operation: "width", inputLayerIDs: ["M1"]),
            ],
            coverage: [
                LayoutRuleCoverage(
                    ruleID: "drc.m1.width",
                    status: .implemented,
                    programNodeIDs: ["n1"],
                    witnessCaseIDs: ["m1-width-fail"]
                )
            ]
        )
        let second = LayoutRuleProgram(
            programID: "sky130A",
            compilerVersion: "compiler-1",
            sourceDeckDigest: "deck-sha",
            nodes: first.nodes.reversed(),
            coverage: first.coverage
        )
        #expect(first.semanticDigest == second.semanticDigest)
        #expect(first.validationErrors().isEmpty)
        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(LayoutRuleProgram.self, from: encoded)
        #expect(decoded == first)
    }

    @Test func semanticDigestPreservesAsymmetricOperandOrder() {
        let first = LayoutRuleProgram(
            programID: "program",
            compilerVersion: "compiler-1",
            sourceDeckDigest: "deck-sha",
            nodes: [LayoutRuleProgramNode(
                nodeID: "n1",
                operation: "difference",
                inputLayerIDs: ["metal", "cut"]
            )],
            coverage: []
        )
        let second = LayoutRuleProgram(
            programID: "program",
            compilerVersion: "compiler-1",
            sourceDeckDigest: "deck-sha",
            nodes: [LayoutRuleProgramNode(
                nodeID: "n1",
                operation: "difference",
                inputLayerIDs: ["cut", "metal"]
            )],
            coverage: []
        )

        #expect(first.semanticDigest != second.semanticDigest)
    }
}
