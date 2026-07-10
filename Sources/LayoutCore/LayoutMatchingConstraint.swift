import Foundation

public struct LayoutMatchingConstraint: Hashable, Sendable, Codable {
    public var members: [UUID]
    public var maxLengthMismatch: Double?
    public var maxWidthMismatch: Double?
    /// If true, orientation mismatch causes immediate SA move rejection.
    public var isHard: Bool

    public init(
        members: [UUID],
        maxLengthMismatch: Double? = nil,
        maxWidthMismatch: Double? = nil,
        isHard: Bool = true
    ) {
        self.members = members
        self.maxLengthMismatch = maxLengthMismatch
        self.maxWidthMismatch = maxWidthMismatch
        self.isHard = isHard
    }

    private enum CodingKeys: String, CodingKey {
        case members, maxLengthMismatch, maxWidthMismatch, isHard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decode([UUID].self, forKey: .members)
        maxLengthMismatch = try container.decodeIfPresent(Double.self, forKey: .maxLengthMismatch)
        maxWidthMismatch = try container.decodeIfPresent(Double.self, forKey: .maxWidthMismatch)
        isHard = try container.decode(Bool.self, forKey: .isHard)
    }
}
