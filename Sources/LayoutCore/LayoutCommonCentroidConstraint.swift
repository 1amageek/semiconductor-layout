import Foundation

public struct LayoutCommonCentroidConstraint: Hashable, Sendable, Codable {
    public var members: [UUID]
    public var pattern: [Int]

    public init(members: [UUID], pattern: [Int]) {
        self.members = members
        self.pattern = pattern
    }
}
