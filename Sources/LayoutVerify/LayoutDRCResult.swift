import Foundation

public struct LayoutDRCResult: Hashable, Sendable, Codable {
    public var violations: [LayoutViolation]

    public init(violations: [LayoutViolation] = []) {
        self.violations = violations
    }

    public var hasErrors: Bool {
        violations.contains { $0.severity == .error }
    }

    public var hasWarnings: Bool {
        violations.contains { $0.severity == .warning }
    }

    public var hasViolations: Bool {
        !violations.isEmpty
    }
}
