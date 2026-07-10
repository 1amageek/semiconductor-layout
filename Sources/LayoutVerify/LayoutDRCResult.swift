import Foundation

public struct LayoutDRCResult: Hashable, Sendable, Codable {
    public var violations: [LayoutViolation]
    public var diagnostics: [LayoutDRCDiagnostic]

    public init(
        violations: [LayoutViolation] = [],
        diagnostics: [LayoutDRCDiagnostic] = []
    ) {
        self.violations = violations
        self.diagnostics = diagnostics
    }

    public var hasErrors: Bool {
        violations.contains { $0.severity == .error }
            || diagnostics.contains { $0.severity == .error }
    }

    public var hasWarnings: Bool {
        violations.contains { $0.severity == .warning }
            || diagnostics.contains { $0.severity == .warning }
    }

    public var hasViolations: Bool {
        !violations.isEmpty
    }

    public var hasDiagnostics: Bool {
        !diagnostics.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case violations
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        violations = try container.decode([LayoutViolation].self, forKey: .violations)
        diagnostics = try container.decode([LayoutDRCDiagnostic].self, forKey: .diagnostics)
    }
}
