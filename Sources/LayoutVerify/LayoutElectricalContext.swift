import LayoutCore

/// The owner whose preparation defines electrical conductor geometry.
public enum LayoutElectricalContext: Sendable, Hashable, Codable {
    /// All selected non-cut source geometry conducts without device recognition.
    case geometric
    /// DeviceExtractor owns ACTIVE/POLY channel separation and material selection.
    case deviceAwareMOS
    /// Explicit material roles identify finite-resistance poly bodies, not ideal wires.
    case deviceAwareMOSAndPolyResistors(polyLayer: LayoutLayerID, bodyMarkerLayer: LayoutLayerID)

    public var rawValue: String {
        switch self {
        case .geometric: "geometric"
        case .deviceAwareMOS: "deviceAwareMOS"
        case .deviceAwareMOSAndPolyResistors: "deviceAwareMOSAndPolyResistors"
        }
    }

    var requiresDevicePreparation: Bool { self != .geometric }

    private enum CodingKeys: String, CodingKey { case profile, polyLayer, bodyMarkerLayer }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        do {
            switch try value.decode(String.self) {
            case "geometric": self = .geometric
            case "deviceAwareMOS": self = .deviceAwareMOS
            default: throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown electrical context")
            }
        } catch DecodingError.typeMismatch {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard try fields.decode(String.self, forKey: .profile) == "deviceAwareMOSAndPolyResistors" else {
                throw DecodingError.dataCorruptedError(forKey: .profile, in: fields, debugDescription: "Unknown electrical context")
            }
            self = .deviceAwareMOSAndPolyResistors(polyLayer: try fields.decode(LayoutLayerID.self, forKey: .polyLayer),
                bodyMarkerLayer: try fields.decode(LayoutLayerID.self, forKey: .bodyMarkerLayer))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .geometric, .deviceAwareMOS:
            var value = encoder.singleValueContainer(); try value.encode(rawValue)
        case .deviceAwareMOSAndPolyResistors(let poly, let marker):
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(rawValue, forKey: .profile)
            try fields.encode(poly, forKey: .polyLayer)
            try fields.encode(marker, forKey: .bodyMarkerLayer)
        }
    }
}
