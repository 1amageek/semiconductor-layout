import Foundation

/// End-cap styles for layout paths.
public enum LayoutPathEndCap: String, Hashable, Sendable, Codable, CaseIterable {
    /// Path ends exactly at the endpoint (flat cut).
    case truncate
    /// Path extends beyond the endpoint by half-width.
    case extend
    /// Semicircular end cap.
    case round

    public var displayLabel: String {
        switch self {
        case .truncate: return "Truncate"
        case .extend: return "Extend"
        case .round: return "Round"
        }
    }
}
