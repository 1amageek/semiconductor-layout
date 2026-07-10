import Foundation
import LayoutCore

public enum DeviceExtractionIssueSeverity: String, Hashable, Sendable, Codable {
    case info
    case warning
    case error
}

public enum DeviceExtractionIssueKind: String, Hashable, Sendable, Codable {
    case ambiguousDeviceType
    case missingTerminal
    case unrecognizedChannel
    /// One connected island carries more than one declared net.
    case shortedNet
    /// One declared net or pin name spans several disconnected islands.
    case openNet
    /// Two pins share a name but resolve to different nets.
    case conflictingPort

    public var defaultCode: String {
        switch self {
        case .ambiguousDeviceType:
            return "layout.extraction.ambiguous-device-type"
        case .missingTerminal:
            return "layout.extraction.missing-terminal"
        case .unrecognizedChannel:
            return "layout.extraction.unrecognized-channel"
        case .shortedNet:
            return "layout.extraction.shorted-net"
        case .openNet:
            return "layout.extraction.open-net"
        case .conflictingPort:
            return "layout.extraction.conflicting-port"
        }
    }

    public var defaultPolicyApplicability: DeviceExtractionPolicyApplicability {
        switch self {
        case .ambiguousDeviceType:
            return .layerMappingReviewRequired
        case .missingTerminal:
            return .layoutRepairRequired
        case .unrecognizedChannel:
            return .layoutRepairRequired
        case .shortedNet:
            return .layoutRepairRequired
        case .openNet:
            return .layoutRepairRequired
        case .conflictingPort:
            return .netAnnotationRequired
        }
    }

    public var defaultSuggestedActions: [String] {
        switch self {
        case .ambiguousDeviceType:
            return ["fix-implant-coverage", "inspect-layer-mapping"]
        case .missingTerminal:
            return ["repair-terminal-connectivity", "inspect-contact-coverage"]
        case .unrecognizedChannel:
            return ["repair-channel-geometry", "inspect-active-poly-crossing"]
        case .shortedNet:
            return ["split-shorted-conductors", "inspect-net-annotations"]
        case .openNet:
            return ["connect-open-net", "inspect-net-annotations"]
        case .conflictingPort:
            return ["deduplicate-port-labels", "inspect-net-annotations"]
        }
    }
}

public enum DeviceExtractionPolicyApplicability: String, Hashable, Sendable, Codable {
    case notApplicable
    case layoutRepairRequired
    case netAnnotationRequired
    case layerMappingReviewRequired
    case policyReviewCandidate
}

public struct DeviceExtractionIssue: Hashable, Sendable, Codable {
    public var kind: DeviceExtractionIssueKind
    public var severity: DeviceExtractionIssueSeverity
    public var code: String
    public var message: String
    public var region: LayoutRect
    public var shapeIDs: [UUID]
    public var affectedDeviceKind: ComparisonDeviceKind?
    public var affectedTerminal: ComparisonTerminalRole?
    public var affectedNet: ComparisonNetID?
    public var affectedLayers: [LayoutLayerID]
    public var policyApplicability: DeviceExtractionPolicyApplicability
    public var suggestedActions: [String]

    public init(
        kind: DeviceExtractionIssueKind,
        severity: DeviceExtractionIssueSeverity = .error,
        code: String? = nil,
        message: String,
        region: LayoutRect,
        shapeIDs: [UUID] = [],
        affectedDeviceKind: ComparisonDeviceKind? = nil,
        affectedTerminal: ComparisonTerminalRole? = nil,
        affectedNet: ComparisonNetID? = nil,
        affectedLayers: [LayoutLayerID] = [],
        policyApplicability: DeviceExtractionPolicyApplicability? = nil,
        suggestedActions: [String]? = nil
    ) {
        self.kind = kind
        self.severity = severity
        self.code = code ?? kind.defaultCode
        self.message = message
        self.region = region
        self.shapeIDs = shapeIDs
        self.affectedDeviceKind = affectedDeviceKind
        self.affectedTerminal = affectedTerminal
        self.affectedNet = affectedNet
        self.affectedLayers = affectedLayers.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.purpose < $1.purpose
        }
        self.policyApplicability = policyApplicability ?? kind.defaultPolicyApplicability
        self.suggestedActions = suggestedActions ?? kind.defaultSuggestedActions
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case severity
        case code
        case message
        case region
        case shapeIDs
        case affectedDeviceKind
        case affectedTerminal
        case affectedNet
        case affectedLayers
        case policyApplicability
        case suggestedActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DeviceExtractionIssueKind.self, forKey: .kind)
        severity = try container.decode(DeviceExtractionIssueSeverity.self, forKey: .severity)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        region = try container.decode(LayoutRect.self, forKey: .region)
        shapeIDs = try container.decode([UUID].self, forKey: .shapeIDs)
        affectedDeviceKind = try container.decodeIfPresent(ComparisonDeviceKind.self, forKey: .affectedDeviceKind)
        affectedTerminal = try container.decodeIfPresent(ComparisonTerminalRole.self, forKey: .affectedTerminal)
        affectedNet = try container.decodeIfPresent(ComparisonNetID.self, forKey: .affectedNet)
        affectedLayers = try container.decode([LayoutLayerID].self, forKey: .affectedLayers).sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.purpose < $1.purpose
        }
        policyApplicability = try container.decode(
            DeviceExtractionPolicyApplicability.self,
            forKey: .policyApplicability
        )
        suggestedActions = try container.decode([String].self, forKey: .suggestedActions)
    }
}
