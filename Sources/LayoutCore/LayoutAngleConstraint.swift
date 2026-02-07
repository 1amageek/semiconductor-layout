import Foundation

/// Angle constraint modes for drawing operations.
public enum LayoutAngleConstraint: String, Hashable, Sendable, Codable, CaseIterable {
    /// Only horizontal and vertical edges (0, 90, 180, 270 degrees).
    case manhattan
    /// Horizontal, vertical, and 45-degree diagonal edges.
    case diagonal
    /// No angle restriction.
    case anyAngle

    public var displayLabel: String {
        switch self {
        case .manhattan: return "Manhattan"
        case .diagonal: return "45°"
        case .anyAngle: return "Any"
        }
    }

    /// Snaps a target point relative to an anchor, constraining the angle
    /// of the segment from anchor to target.
    public func snap(_ target: LayoutPoint, from anchor: LayoutPoint) -> LayoutPoint {
        switch self {
        case .anyAngle:
            return target
        case .manhattan:
            return snapManhattan(target, from: anchor)
        case .diagonal:
            return snapDiagonal(target, from: anchor)
        }
    }

    private func snapManhattan(_ target: LayoutPoint, from anchor: LayoutPoint) -> LayoutPoint {
        let dx = target.x - anchor.x
        let dy = target.y - anchor.y
        if abs(dx) >= abs(dy) {
            return LayoutPoint(x: target.x, y: anchor.y)
        } else {
            return LayoutPoint(x: anchor.x, y: target.y)
        }
    }

    private func snapDiagonal(_ target: LayoutPoint, from anchor: LayoutPoint) -> LayoutPoint {
        let dx = target.x - anchor.x
        let dy = target.y - anchor.y
        let adx = abs(dx)
        let ady = abs(dy)

        // Determine closest allowed angle: 0, 45, 90, 135, 180, 225, 270, 315
        let angle = atan2(dy, dx)

        // 8 sectors, each spanning pi/4 (45 degrees)
        let sector = Int(round(angle / (Double.pi / 4)))

        switch ((sector % 8) + 8) % 8 {
        case 0: // 0° (right)
            return LayoutPoint(x: anchor.x + adx, y: anchor.y)
        case 1: // 45° (up-right)
            let d = max(adx, ady)
            return LayoutPoint(x: anchor.x + d * (dx >= 0 ? 1 : -1),
                             y: anchor.y + d * (dy >= 0 ? 1 : -1))
        case 2: // 90° (up)
            return LayoutPoint(x: anchor.x, y: anchor.y + ady)
        case 3: // 135° (up-left)
            let d = max(adx, ady)
            return LayoutPoint(x: anchor.x + d * (dx >= 0 ? 1 : -1),
                             y: anchor.y + d * (dy >= 0 ? 1 : -1))
        case 4: // 180° (left)
            return LayoutPoint(x: anchor.x - adx, y: anchor.y)
        case 5: // 225° (down-left)
            let d = max(adx, ady)
            return LayoutPoint(x: anchor.x + d * (dx >= 0 ? 1 : -1),
                             y: anchor.y + d * (dy >= 0 ? 1 : -1))
        case 6: // 270° (down)
            return LayoutPoint(x: anchor.x, y: anchor.y - ady)
        case 7: // 315° (down-right)
            let d = max(adx, ady)
            return LayoutPoint(x: anchor.x + d * (dx >= 0 ? 1 : -1),
                             y: anchor.y + d * (dy >= 0 ? 1 : -1))
        default:
            return target
        }
    }
}
