import Foundation

public struct LiveConstraintUpdate: Hashable, Sendable {
    public var violations: [LayoutConstraintViolation]
    public var recomputedConstraintIndices: [Int]
    public var skippedConstraintCount: Int

    public init(
        violations: [LayoutConstraintViolation],
        recomputedConstraintIndices: [Int],
        skippedConstraintCount: Int
    ) {
        self.violations = violations
        self.recomputedConstraintIndices = recomputedConstraintIndices
        self.skippedConstraintCount = skippedConstraintCount
    }
}
