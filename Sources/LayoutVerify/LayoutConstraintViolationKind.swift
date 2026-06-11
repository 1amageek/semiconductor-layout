import Foundation

public enum LayoutConstraintViolationKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// A constraint references a member ID that resolves to neither a
    /// shape nor an instance of the checked cell.
    case unresolvedMember
    /// The constraint itself is ill-formed (odd symmetry member count,
    /// empty pattern, fewer than two members, ...).
    case malformedConstraint
    /// A symmetry pair does not mirror across the axis.
    case symmetryPairMismatch
    /// A self-symmetric member's center is off the symmetry axis.
    case symmetryAxisMemberOffAxis
    /// Matched members differ in bounding-box width beyond the budget.
    case matchingWidthMismatch
    /// Matched members differ in bounding-box height beyond the budget.
    case matchingLengthMismatch
    /// An aligned member's coordinate deviates from the reference.
    case alignmentMismatch
    /// A common-centroid group's centroid deviates from the overall centroid.
    case centroidMismatch
    /// Members do not interleave in the declared pattern order.
    case interdigitationOrderMismatch
}
