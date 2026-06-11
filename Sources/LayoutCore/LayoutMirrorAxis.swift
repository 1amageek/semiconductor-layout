import Foundation

/// Mirror line orientation for shape mirroring.
public enum LayoutMirrorAxis: Sendable, Hashable {
    /// Mirror across a vertical line: x coordinates flip, a left-right flip.
    case vertical
    /// Mirror across a horizontal line: y coordinates flip, an up-down flip.
    case horizontal
}
