import Foundation

/// Endpoint geometry in micrometers, ordered along the original centerline.
public enum LayoutPathEndCap: Hashable, Sendable, Codable {
    case truncate
    case extend
    case round
    case custom(begin: Double, end: Double)

    /// Styles that can be selected without entering explicit distances.
    public static let standardStyles: [Self] = [.truncate, .extend, .round]

    public var isValid: Bool {
        if case .custom(let begin, let end) = self { return begin.isFinite && end.isFinite }
        return true
    }

    public var displayLabel: String {
        switch self {
        case .truncate: return "Truncate"
        case .extend: return "Extend"
        case .round: return "Round"
        case .custom: return "Custom"
        }
    }

    public func scaled(by magnitude: Double) -> Self {
        if case .custom(let begin, let end) = self {
            return .custom(begin: begin * magnitude, end: end * magnitude)
        }
        return self
    }

    /// Stable geometry ordering includes both explicit endpoint distances.
    public var geometryOrderKey: String {
        switch self {
        case .truncate: return "truncate"
        case .extend: return "extend"
        case .round: return "round"
        case .custom(let begin, let end): return "custom|\(begin)|\(end)"
        }
    }
}
