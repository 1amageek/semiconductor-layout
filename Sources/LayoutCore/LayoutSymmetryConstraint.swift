import Foundation

public struct LayoutSymmetryConstraint: Hashable, Sendable, Codable {
    public var axis: LayoutSymmetryAxis
    /// Paired members: indices (0,1), (2,3), ... are symmetric pairs.
    public var members: [UUID]
    /// Fixed axis position. If nil, computed once from initial placement.
    public var axisPosition: Double?
    /// Members that must sit ON the axis of symmetry (e.g., tail current source).
    public var selfSymmetricMembers: [UUID]
    /// If true, symmetry violations cause immediate SA move rejection.
    public var isHard: Bool

    public init(
        axis: LayoutSymmetryAxis,
        members: [UUID],
        axisPosition: Double? = nil,
        selfSymmetricMembers: [UUID] = [],
        isHard: Bool = true
    ) {
        self.axis = axis
        self.members = members
        self.axisPosition = axisPosition
        self.selfSymmetricMembers = selfSymmetricMembers
        self.isHard = isHard
    }

    private enum CodingKeys: String, CodingKey {
        case axis, members, axisPosition, selfSymmetricMembers, isHard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        axis = try container.decode(LayoutSymmetryAxis.self, forKey: .axis)
        members = try container.decode([UUID].self, forKey: .members)
        axisPosition = try container.decodeIfPresent(Double.self, forKey: .axisPosition)
        selfSymmetricMembers = try container.decode([UUID].self, forKey: .selfSymmetricMembers)
        isHard = try container.decode(Bool.self, forKey: .isHard)
    }
}
