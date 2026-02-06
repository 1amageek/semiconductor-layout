import Foundation

public struct LayoutMatchingConstraint: Hashable, Sendable, Codable {
    public var members: [UUID]
    public var maxLengthMismatch: Double?
    public var maxWidthMismatch: Double?

    public init(members: [UUID], maxLengthMismatch: Double? = nil, maxWidthMismatch: Double? = nil) {
        self.members = members
        self.maxLengthMismatch = maxLengthMismatch
        self.maxWidthMismatch = maxWidthMismatch
    }
}
