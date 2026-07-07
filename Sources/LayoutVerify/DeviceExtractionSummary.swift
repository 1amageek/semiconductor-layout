import Foundation
import LayoutCore

public struct DeviceExtractionSummary: Hashable, Sendable, Codable {
    public var issueCount: Int
    public var errorCount: Int
    public var warningCount: Int
    public var infoCount: Int
    public var policyReviewCandidateCount: Int
    public var issueCountsByKind: [String: Int]
    public var issueCountsByCode: [String: Int]
    public var issueCountsByPolicyApplicability: [String: Int]
    public var affectedDeviceKinds: [String]
    public var affectedTerminals: [String]
    public var affectedNets: [String]
    public var affectedLayers: [String]
    public var suggestedActions: [String]

    public init(
        issueCount: Int = 0,
        errorCount: Int = 0,
        warningCount: Int = 0,
        infoCount: Int = 0,
        policyReviewCandidateCount: Int = 0,
        issueCountsByKind: [String: Int] = [:],
        issueCountsByCode: [String: Int] = [:],
        issueCountsByPolicyApplicability: [String: Int] = [:],
        affectedDeviceKinds: [String] = [],
        affectedTerminals: [String] = [],
        affectedNets: [String] = [],
        affectedLayers: [String] = [],
        suggestedActions: [String] = []
    ) {
        self.issueCount = issueCount
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.infoCount = infoCount
        self.policyReviewCandidateCount = policyReviewCandidateCount
        self.issueCountsByKind = issueCountsByKind
        self.issueCountsByCode = issueCountsByCode
        self.issueCountsByPolicyApplicability = issueCountsByPolicyApplicability
        self.affectedDeviceKinds = affectedDeviceKinds
        self.affectedTerminals = affectedTerminals
        self.affectedNets = affectedNets
        self.affectedLayers = affectedLayers
        self.suggestedActions = suggestedActions
    }

    public init(issues: [DeviceExtractionIssue]) {
        var kindCounts: [String: Int] = [:]
        var codeCounts: [String: Int] = [:]
        var policyCounts: [String: Int] = [:]
        var deviceKinds = Set<String>()
        var terminals = Set<String>()
        var nets = Set<String>()
        var layers = Set<String>()
        var actions = Set<String>()
        var policyReviewCandidateCount = 0
        var errorCount = 0
        var warningCount = 0
        var infoCount = 0

        for issue in issues {
            kindCounts[issue.kind.rawValue, default: 0] += 1
            codeCounts[issue.code, default: 0] += 1
            policyCounts[issue.policyApplicability.rawValue, default: 0] += 1
            switch issue.severity {
            case .error:
                errorCount += 1
            case .warning:
                warningCount += 1
            case .info:
                infoCount += 1
            }
            if issue.policyApplicability == .policyReviewCandidate {
                policyReviewCandidateCount += 1
            }
            if let affectedDeviceKind = issue.affectedDeviceKind {
                deviceKinds.insert(affectedDeviceKind.rawValue)
            }
            if let affectedTerminal = issue.affectedTerminal {
                terminals.insert(affectedTerminal.rawValue)
            }
            if let affectedNet = issue.affectedNet {
                nets.insert(affectedNet.rawValue)
            }
            for layer in issue.affectedLayers {
                layers.insert(Self.layerIdentifier(layer))
            }
            actions.formUnion(issue.suggestedActions)
        }

        self.init(
            issueCount: issues.count,
            errorCount: errorCount,
            warningCount: warningCount,
            infoCount: infoCount,
            policyReviewCandidateCount: policyReviewCandidateCount,
            issueCountsByKind: kindCounts,
            issueCountsByCode: codeCounts,
            issueCountsByPolicyApplicability: policyCounts,
            affectedDeviceKinds: deviceKinds.sorted(),
            affectedTerminals: terminals.sorted(),
            affectedNets: nets.sorted(),
            affectedLayers: layers.sorted(),
            suggestedActions: actions.sorted()
        )
    }

    public static func layerIdentifier(_ layer: LayoutLayerID) -> String {
        "\(layer.name)/\(layer.purpose)"
    }
}
