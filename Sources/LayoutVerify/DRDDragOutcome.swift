import Foundation

/// How a design-rule-driven drag resolved a proposed offset.
public enum DRDDragOutcome: Hashable, Sendable {
    /// The proposal itself is legal; the geometry follows the cursor.
    case followed

    /// The proposal would create a new violation; the geometry stuck at
    /// the closest legal offset along the path from the last legal one.
    case constrained

    /// No legal offset exists along the path, including the last legal
    /// offset re-check; the geometry stayed at the last legal offset.
    case blocked
}
