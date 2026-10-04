import Foundation
import LayoutCore

public struct LayoutDRCResult: Hashable, Sendable, Codable {
    public var violations: [LayoutViolation]
    public var diagnostics: [LayoutDRCDiagnostic]
    /// Owned source generation for scoped electrical references and pin indices.
    public var electricalContext: LayoutElectricalContext
    public var sourceHierarchy: LayoutHierarchySnapshot?

    public init(
        violations: [LayoutViolation] = [],
        diagnostics: [LayoutDRCDiagnostic] = [],
        sourceHierarchy: LayoutHierarchySnapshot? = nil,
        electricalContext: LayoutElectricalContext = .geometric
    ) {
        self.violations = violations
        self.diagnostics = diagnostics
        self.sourceHierarchy = sourceHierarchy
        self.electricalContext = electricalContext
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
        case sourceHierarchy
        case electricalContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        violations = try container.decode([LayoutViolation].self, forKey: .violations)
        diagnostics = try container.decode([LayoutDRCDiagnostic].self, forKey: .diagnostics)
        electricalContext = try container.decode(LayoutElectricalContext.self, forKey: .electricalContext)
        sourceHierarchy = try container.decodeIfPresent(LayoutHierarchySnapshot.self, forKey: .sourceHierarchy)
        for violation in violations where !violation.netReferences.isEmpty || !violation.sourcePinIndices.isEmpty {
            guard let hierarchy = sourceHierarchy,
                  violation.netReferences.allSatisfy({ hierarchy.occurrences.indices.contains($0.occurrenceIndex) }),
                  violation.sourcePinIndices.allSatisfy({ hierarchy.pins.indices.contains($0) }) else {
                throw DecodingError.dataCorruptedError(forKey: .sourceHierarchy, in: container,
                    debugDescription: "Scoped electrical evidence requires its owned source generation.")
            }
        }
    }
}
