import Foundation

public struct LayoutDRCResult: Hashable, Sendable, Codable {
    public var violations: [LayoutViolation]

    public init(violations: [LayoutViolation] = []) {
        self.violations = violations
    }

    public var hasErrors: Bool {
        !violations.isEmpty
    }
}
