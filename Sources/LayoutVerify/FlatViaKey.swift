import Foundation

/// Stable identity of one flattened via occurrence inside a connectivity
/// session generation.
///
/// Top-level vias are identified by their UUID, which the session
/// guarantees unique among editable vias. Child-cell contributions are
/// identified by their position in the flattened child array instead,
/// because a cell instantiated more than once flattens the same via UUID
/// into several distinct occurrences; the child array is constant between
/// rebuilds, so the position is stable.
enum FlatViaKey: Hashable, Comparable, Sendable {
    case top(UUID)
    case child(Int)

    /// Total order for deterministic component canonicalisation: child
    /// occurrences by position first, then top vias in canonical UUID
    /// order (identical to `uuidString` order, without the allocations).
    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.top(a), .top(b)): return a.isCanonicallyOrderedBefore(b)
        case let (.child(a), .child(b)): return a < b
        case (.child, .top): return true
        case (.top, .child): return false
        }
    }
}
