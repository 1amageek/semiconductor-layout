import Foundation

/// Stable identity of one conductor element — a flattened shape or via
/// occurrence — inside a connectivity generation.
///
/// Extraction treats shapes and vias as one element universe, so component
/// membership needs a key space spanning both. The order is total and
/// deterministic: all shapes precede all vias, each in its own key order,
/// which makes sorted member lists canonical between the batch extractor
/// and the live session.
enum ConnectivityElementKey: Hashable, Comparable, Sendable {
    case shape(FlatShapeKey)
    case via(FlatViaKey)

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.shape(a), .shape(b)): return a < b
        case let (.via(a), .via(b)): return a < b
        case (.shape, .via): return true
        case (.via, .shape): return false
        }
    }
}
