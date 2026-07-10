import Foundation

/// Aligns a group of members along one coordinate: a shared edge or a
/// shared center line of their bounding boxes. The first member is the
/// reference; every other member's alignment coordinate must match it
/// within `tolerance`.
public struct LayoutAlignmentConstraint: Hashable, Sendable, Codable {
    /// Which bounding-box coordinate the members share.
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        case minX
        case centerX
        case maxX
        case minY
        case centerY
        case maxY
    }

    public var mode: Mode
    public var members: [UUID]
    /// Allowed deviation from the reference member's coordinate.
    public var tolerance: Double
    /// If true, violations are errors; otherwise warnings.
    public var isHard: Bool

    public init(
        mode: Mode,
        members: [UUID],
        tolerance: Double = 0,
        isHard: Bool = true
    ) {
        self.mode = mode
        self.members = members
        self.tolerance = tolerance
        self.isHard = isHard
    }

    private enum CodingKeys: String, CodingKey {
        case mode, members, tolerance, isHard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        members = try container.decode([UUID].self, forKey: .members)
        tolerance = try container.decode(Double.self, forKey: .tolerance)
        isHard = try container.decode(Bool.self, forKey: .isHard)
    }
}
