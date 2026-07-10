import Foundation
import CryptoKit
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
        id: UUID? = nil,
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
        self.id = id ?? Self.deterministicID(
            kind: kind,
            ruleID: ruleID,
            severity: severity,
            message: message,
            layer: layer,
            region: region,
            measured: measured,
            required: required,
            unit: unit,
            shapeIDs: shapeIDs,
            viaIDs: viaIDs,
            pinIDs: pinIDs,
            netIDs: netIDs,
            suggestedFix: suggestedFix
        )
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
        severity = try container.decode(LayoutViolationSeverity.self, forKey: .severity)
        message = try container.decode(String.self, forKey: .message)
        layer = try container.decodeIfPresent(LayoutLayerID.self, forKey: .layer)
        region = try container.decode(LayoutRect.self, forKey: .region)
        measured = try container.decodeIfPresent(Double.self, forKey: .measured)
        required = try container.decodeIfPresent(Double.self, forKey: .required)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        shapeIDs = try container.decode([UUID].self, forKey: .shapeIDs)
        viaIDs = try container.decode([UUID].self, forKey: .viaIDs)
        pinIDs = try container.decode([UUID].self, forKey: .pinIDs)
        netIDs = try container.decode([UUID].self, forKey: .netIDs)
        suggestedFix = try container.decodeIfPresent(String.self, forKey: .suggestedFix)
    }

    private static func deterministicID(
        kind: LayoutViolationKind,
        ruleID: String?,
        severity: LayoutViolationSeverity,
        message: String,
        layer: LayoutLayerID?,
        region: LayoutRect,
        measured: Double?,
        required: Double?,
        unit: String?,
        shapeIDs: [UUID],
        viaIDs: [UUID],
        pinIDs: [UUID],
        netIDs: [UUID],
        suggestedFix: String?
    ) -> UUID {
        let parts = [
            "layout-violation",
            "kind=\(kind.rawValue)",
            "ruleID=\(ruleID ?? "")",
            "severity=\(severity.rawValue)",
            "message=\(message)",
            "layer=\(layer.map { "\($0.name):\($0.purpose)" } ?? "")",
            "region=\(region.origin.x),\(region.origin.y),\(region.size.width),\(region.size.height)",
            "measured=\(measured.map(String.init(describing:)) ?? "")",
            "required=\(required.map(String.init(describing:)) ?? "")",
            "unit=\(unit ?? "")",
            "shapeIDs=\(shapeIDs.map(\.uuidString).joined(separator: ","))",
            "viaIDs=\(viaIDs.map(\.uuidString).joined(separator: ","))",
            "pinIDs=\(pinIDs.map(\.uuidString).joined(separator: ","))",
            "netIDs=\(netIDs.map(\.uuidString).joined(separator: ","))",
            "suggestedFix=\(suggestedFix ?? "")",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
