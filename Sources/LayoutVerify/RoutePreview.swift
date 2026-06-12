import Foundation
import LayoutCore

public enum RouteMode: String, Hashable, Sendable, Codable {
    case manual
    case autoComplete
    case shove
}

public enum RouteSnapReason: String, Hashable, Sendable, Codable {
    case none
    case grid
    case sameNetShapeEdge
    case sameNetPin
}

public enum RouteStopReason: Hashable, Sendable {
    case blockedByViolations([LayoutViolation])
}

public struct RoutePreview: Sendable {
    public var mode: RouteMode
    public var requestedEnd: LayoutPoint
    public var legalEnd: LayoutPoint
    public var snapReason: RouteSnapReason
    public var stopReason: RouteStopReason?
    public var delta: LayoutEditDelta
    public var violations: [LayoutViolation]
    /// Neighbours the shove resolution has displaced, at their current
    /// preview positions — the canvas draws these so the user sees the
    /// push before committing it.
    public var pushedShapes: [LayoutShape]

    public init(
        mode: RouteMode,
        requestedEnd: LayoutPoint,
        legalEnd: LayoutPoint,
        snapReason: RouteSnapReason,
        stopReason: RouteStopReason? = nil,
        delta: LayoutEditDelta,
        violations: [LayoutViolation] = [],
        pushedShapes: [LayoutShape] = []
    ) {
        self.mode = mode
        self.requestedEnd = requestedEnd
        self.legalEnd = legalEnd
        self.snapReason = snapReason
        self.stopReason = stopReason
        self.delta = delta
        self.violations = violations
        self.pushedShapes = pushedShapes
    }

    public var isLegal: Bool {
        stopReason == nil
    }
}
