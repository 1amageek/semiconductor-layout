import Foundation

/// One physical band, independently keyed from its editor highlight source.
/// Band zero is the first captured band, never an aggregate source node.
enum ConnectivityElementKey: Hashable, Comparable, Sendable {
    case shape(FlatShapeKey, band: Int = 0)
    case via(FlatViaKey, band: Int = 0)

    var sourceKey: Self {
        switch self {
        case .shape(let source, _): return .shape(source)
        case .via(let source, _): return .via(source)
        }
    }

    func band(_ index: Int) -> Self {
        switch self {
        case .shape(let source, _): return .shape(source, band: index)
        case .via(let source, _): return .via(source, band: index)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.shape(a, first), .shape(b, second)):
            return a == b ? first < second : a < b
        case let (.via(a, first), .via(b, second)):
            return a == b ? first < second : a < b
        case (.shape, .via): return true
        case (.via, .shape): return false
        }
    }
}
