import Foundation
import LayoutCore

/// A computed, ready-to-apply fix for one violation: the delta that
/// resolves it, verified against a DRC mirror before being offered.
///
/// A repair is a GOAL artifact, not a suggestion string: applying its
/// delta through the editor's single edit stream removes the violation
/// without creating new error-class violations — that contract is checked
/// at computation time, so an offered repair never surprises.
public struct LayoutRepair: Sendable {
    /// The violation this repair resolves.
    public var violationID: UUID
    /// The verified document delta (one undo unit when applied).
    public var delta: LayoutEditDelta
    /// Human-readable action summary (English, shown in UI).
    public var summary: String

    public init(violationID: UUID, delta: LayoutEditDelta, summary: String) {
        self.violationID = violationID
        self.delta = delta
        self.summary = summary
    }
}

/// Why a violation has no computed repair. Infeasibility is a first-class
/// answer — the engine never silently skips a violation.
public enum LayoutRepairInfeasibility: Sendable, Equatable {
    /// The violation kind has no automated repair strategy yet; the
    /// associated text names the manual path.
    case unsupportedKind(String)
    /// Every candidate fix created new violations elsewhere.
    case blockedByNeighbours
    /// The violating geometry is not rectangular; growth/displacement
    /// strategies need a rect.
    case nonRectangularGeometry
    /// The violation references geometry the engine cannot edit (child
    /// occurrences of an instance).
    case childGeometry
    /// The violation payload lacks the references the strategy needs.
    case missingContext(String)
}

public enum LayoutRepairOutcome: Sendable {
    case repair(LayoutRepair)
    case infeasible(LayoutRepairInfeasibility)
}

/// Result of a fix-all convergence run: what was applied, what remains
/// with reasons, and whether a fixed point was reached within budget.
public struct LayoutRepairSweep: Sendable {
    public var appliedSummaries: [String]
    public var residuals: [(violation: LayoutViolation, reason: LayoutRepairInfeasibility)]
    public var reachedFixedPoint: Bool

    public init(
        appliedSummaries: [String],
        residuals: [(violation: LayoutViolation, reason: LayoutRepairInfeasibility)],
        reachedFixedPoint: Bool
    ) {
        self.appliedSummaries = appliedSummaries
        self.residuals = residuals
        self.reachedFixedPoint = reachedFixedPoint
    }
}
