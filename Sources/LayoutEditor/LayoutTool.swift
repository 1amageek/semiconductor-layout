import Foundation

public enum LayoutTool: String, CaseIterable, Sendable {
    case select
    case rectangle
    case polygon
    case path
    case route
    case subtract
    case split
    case merge
    case ruler
    case via
    case label
    case pin

    public var displayLabel: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon"
        case .path: return "Path"
        case .route: return "Route"
        case .subtract: return "Subtract"
        case .split: return "Split"
        case .merge: return "Merge"
        case .ruler: return "Ruler"
        case .via: return "Via"
        case .label: return "Label"
        case .pin: return "Pin"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: return "arrow.uturn.left"
        case .rectangle: return "rectangle"
        case .polygon: return "pentagon"
        case .path: return "line.diagonal"
        case .route: return "point.topleft.down.curvedto.point.bottomright.up"
        case .subtract: return "rectangle.badge.minus"
        case .split: return "scissors"
        case .merge: return "arrow.triangle.merge"
        case .ruler: return "ruler"
        case .via: return "circle.circle"
        case .label: return "tag"
        case .pin: return "mappin"
        }
    }

    /// Keyboard shortcut. Follows Cadence Virtuoso conventions where possible.
    public var shortcutKey: Character? {
        switch self {
        case .select: return "s"
        case .rectangle: return "r"
        case .polygon: return "g"
        case .path: return "p"
        case .route: return "w"
        case .subtract: return "x"
        case .split: return "c"
        case .merge: return "e"
        case .ruler: return "k"
        case .via: return "o"
        case .label: return "l"
        case .pin: return "i"
        }
    }
}
