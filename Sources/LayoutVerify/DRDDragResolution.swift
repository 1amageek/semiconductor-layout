import Foundation
import LayoutCore

/// Result of one design-rule-driven drag proposal: the offset that was
/// actually applied, how it relates to the proposal, and the live DRC
/// snapshot at that offset.
public struct DRDDragResolution: Sendable {
    /// Offset from the drag origin that the dragged geometry now sits at.
    public let appliedOffset: LayoutPoint

    /// How the proposal resolved.
    public let outcome: DRDDragOutcome

    /// Violation snapshot at `appliedOffset`, exact except for the kinds
    /// in its `staleKinds` (the session's deferred tier).
    public let result: LayoutDRCResult

    public init(appliedOffset: LayoutPoint, outcome: DRDDragOutcome, result: LayoutDRCResult) {
        self.appliedOffset = appliedOffset
        self.outcome = outcome
        self.result = result
    }
}
