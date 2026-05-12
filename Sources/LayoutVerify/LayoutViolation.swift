import Foundation
import LayoutCore

public struct LayoutViolation: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var kind: LayoutViolationKind
    public var ruleID: String?
    public var severity: LayoutViolationSeverity
    public var message: String
    public var layer: LayoutLayerID?
    public var region: LayoutRect
    public var measured: Double?
    public var required: Double?
    public var unit: String?
    public var shapeIDs: [UUID]
    public var viaIDs: [UUID]
    public var pinIDs: [UUID]
    public var netIDs: [UUID]
    public var suggestedFix: String?

    public init(
        id: UUID = UUID(),
        kind: LayoutViolationKind,
        ruleID: String? = nil,
        severity: LayoutViolationSeverity = .error,
        message: String,
        layer: LayoutLayerID? = nil,
        region: LayoutRect = .zero,
        measured: Double? = nil,
        required: Double? = nil,
        unit: String? = nil,
        shapeIDs: [UUID] = [],
        viaIDs: [UUID] = [],
        pinIDs: [UUID] = [],
        netIDs: [UUID] = [],
        suggestedFix: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.layer = layer
        self.region = region
        self.measured = measured
        self.required = required
        self.unit = unit
        self.shapeIDs = shapeIDs
        self.viaIDs = viaIDs
        self.pinIDs = pinIDs
        self.netIDs = netIDs
        self.suggestedFix = suggestedFix
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case ruleID
        case severity
        case message
        case layer
        case region
        case measured
        case required
        case unit
        case shapeIDs
        case viaIDs
        case pinIDs
        case netIDs
        case suggestedFix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(LayoutViolationKind.self, forKey: .kind)
        ruleID = try container.decodeIfPresent(String.self, forKey: .ruleID)
        severity = try container.decodeIfPresent(LayoutViolationSeverity.self, forKey: .severity) ?? .error
        message = try container.decode(String.self, forKey: .message)
        layer = try container.decodeIfPresent(LayoutLayerID.self, forKey: .layer)
        region = try container.decodeIfPresent(LayoutRect.self, forKey: .region) ?? .zero
        measured = try container.decodeIfPresent(Double.self, forKey: .measured)
        required = try container.decodeIfPresent(Double.self, forKey: .required)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        shapeIDs = try container.decodeIfPresent([UUID].self, forKey: .shapeIDs) ?? []
        viaIDs = try container.decodeIfPresent([UUID].self, forKey: .viaIDs) ?? []
        pinIDs = try container.decodeIfPresent([UUID].self, forKey: .pinIDs) ?? []
        netIDs = try container.decodeIfPresent([UUID].self, forKey: .netIDs) ?? []
        suggestedFix = try container.decodeIfPresent(String.self, forKey: .suggestedFix)
    }
}
