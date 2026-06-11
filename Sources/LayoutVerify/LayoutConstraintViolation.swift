import Foundation
import LayoutCore

/// A broken design-intent constraint, reported like a DRC violation:
/// what is broken, by how much, where, and which members are involved.
public struct LayoutConstraintViolation: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var kind: LayoutConstraintViolationKind
    /// Index of the offending constraint in the cell's `constraints` array.
    public var constraintIndex: Int
    public var severity: LayoutViolationSeverity
    public var message: String
    /// Union of the involved members' bounding boxes (zero if unresolvable).
    public var region: LayoutRect
    public var memberIDs: [UUID]
    public var measured: Double?
    public var required: Double?

    public init(
        id: UUID = UUID(),
        kind: LayoutConstraintViolationKind,
        constraintIndex: Int,
        severity: LayoutViolationSeverity = .error,
        message: String,
        region: LayoutRect = .zero,
        memberIDs: [UUID] = [],
        measured: Double? = nil,
        required: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.constraintIndex = constraintIndex
        self.severity = severity
        self.message = message
        self.region = region
        self.memberIDs = memberIDs
        self.measured = measured
        self.required = required
    }
}
