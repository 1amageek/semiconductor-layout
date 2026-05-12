import Foundation

public enum LayoutRotation: Int, Sendable, Codable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    public var degrees: Double {
        Double(rawValue)
    }

    public init(nearestTo degrees: Double) {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        if normalized < 45 || normalized >= 315 {
            self = .deg0
        } else if normalized < 135 {
            self = .deg90
        } else if normalized < 225 {
            self = .deg180
        } else {
            self = .deg270
        }
    }
}
