import Foundation

/// Design-rule-driven editing mode: how live DRC results steer
/// interactive edits.
public enum DRDMode: String, CaseIterable, Sendable {
    /// Live verification off; DRC runs only on demand.
    case off

    /// Every edit re-verifies incrementally and violation markers update
    /// live, but edits are never constrained.
    case observe

    /// Like ``observe``, and interactive drags additionally stick at the
    /// closest legal position instead of landing in a new violation.
    case enforce

    public var displayName: String {
        switch self {
        case .off: return "DRD Off"
        case .observe: return "DRD Observe"
        case .enforce: return "DRD Enforce"
        }
    }
}
