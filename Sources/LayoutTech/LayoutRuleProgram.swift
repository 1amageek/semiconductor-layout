import CryptoKit
import Foundation

/// Deterministic, versioned rule program contract for foundry semantics.
public struct LayoutRuleProgram: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let programID: String
    public let compilerVersion: String
    public let sourceDeckDigest: String
    public let semanticDigest: String
    public let nodes: [LayoutRuleProgramNode]
    public let coverage: [LayoutRuleCoverage]

    public init(
        programID: String,
        compilerVersion: String,
        sourceDeckDigest: String,
        nodes: [LayoutRuleProgramNode],
        coverage: [LayoutRuleCoverage],
        schemaVersion: Int = LayoutRuleProgram.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.programID = programID
        self.compilerVersion = compilerVersion
        self.sourceDeckDigest = sourceDeckDigest
        self.nodes = nodes.sorted { $0.nodeID < $1.nodeID }
        self.coverage = coverage.sorted { $0.ruleID < $1.ruleID }
        self.semanticDigest = Self.digest(
            compilerVersion: compilerVersion,
            sourceDeckDigest: sourceDeckDigest,
            nodes: self.nodes,
            coverage: self.coverage
        )
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        let nodeIDs = nodes.map(\.nodeID)
        let coverageIDs = coverage.map(\.ruleID)
        if Set(nodeIDs).count != nodeIDs.count {
            errors.append("duplicate-rule-program-node-id")
        }
        if Set(coverageIDs).count != coverageIDs.count {
            errors.append("duplicate-rule-coverage-id")
        }
        if coverage.contains(where: { $0.status == .implemented && $0.programNodeIDs.isEmpty }) {
            errors.append("implemented-rule-missing-program-node")
        }
        if coverage.contains(where: { $0.status == .unsupported && ($0.rationale ?? "").isEmpty }) {
            errors.append("unsupported-rule-missing-rationale")
        }
        return errors
    }

    private static func digest(
        compilerVersion: String,
        sourceDeckDigest: String,
        nodes: [LayoutRuleProgramNode],
        coverage: [LayoutRuleCoverage]
    ) -> String {
        let nodePayload = nodes.map { node in
            let parameters = node.parameters.keys.sorted().map { "\($0)=\(node.parameters[$0] ?? "")" }.joined(separator: ",")
            return [node.nodeID, node.operation, node.inputLayerIDs.joined(separator: ","), parameters]
                .joined(separator: "|")
        }.joined(separator: "\n")
        let coveragePayload = coverage.map { entry in
            [
                entry.ruleID,
                entry.status.rawValue,
                entry.sourceRuleIDs.joined(separator: ","),
                entry.programNodeIDs.joined(separator: ","),
                entry.witnessCaseIDs.joined(separator: ","),
                entry.rationale ?? ""
            ].joined(separator: "|")
        }.joined(separator: "\n")
        let payload = [compilerVersion, sourceDeckDigest, nodePayload, coveragePayload].joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
