import Foundation

public struct LayoutSymmetryConstraint: Hashable, Sendable, Codable {
    public var axis: LayoutSymmetryAxis
    public var members: [UUID]

    public init(axis: LayoutSymmetryAxis, members: [UUID]) {
        self.axis = axis
        self.members = members
    }
}
