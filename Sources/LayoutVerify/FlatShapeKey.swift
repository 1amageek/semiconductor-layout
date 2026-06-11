import Foundation

/// Stable identity of one flattened shape occurrence inside an incremental
/// session generation.
///
/// Top-level shapes are identified by their UUID, which the session
/// guarantees unique among editable shapes. Child-cell contributions are
/// identified by their position in the flattened child array instead,
/// because a cell instantiated more than once flattens the same shape
/// UUID into several distinct occurrences; the child array is constant
/// between rebuilds, so the position is stable.
enum FlatShapeKey: Hashable, Comparable, Sendable {
    case top(UUID)
    case child(Int)

    /// Total order for deterministic cluster keys and assembly: child
    /// occurrences by position first, then top shapes by UUID string.
    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.top(a), .top(b)): return a.uuidString < b.uuidString
        case let (.child(a), .child(b)): return a < b
        case (.child, .top): return true
        case (.top, .child): return false
        }
    }
}
