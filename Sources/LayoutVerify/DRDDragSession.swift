import Foundation
import LayoutCore

/// Design-rule-driven drag of a set of shapes over a live
/// ``IncrementalDRCSession``.
///
/// The drag session owns the dragged shapes' geometry inside the DRC
/// session for its lifetime: every proposal is applied as an update delta
/// and verified incrementally, so the caller always renders from an exact
/// snapshot. In enforce mode an illegal proposal is resolved to the
/// closest legal offset along the path from the last legal offset, probed
/// against the same oracle the signoff run uses — there is no separate,
/// approximate legality model that could disagree with the checker.
///
/// Legality is relative to the drag's starting state: a violation whose
/// ``ViolationIdentity`` already existed at the drag origin may persist
/// (the user can always drag a violating shape), but no identity absent
/// at the origin may appear. Overlap and abutment on the same layer merge
/// into one component and are therefore naturally legal.
public final class DRDDragSession {
    private let session: IncrementalDRCSession
    private let originalShapes: [LayoutShape]
    private let draggedIDs: Set<UUID>
    private let grid: Double
    private let baseline: Set<ViolationIdentity>

    /// Offset currently applied inside the DRC session.
    public private(set) var currentOffset: LayoutPoint = .zero

    /// Last offset known to be legal; the anchor of enforce-mode searches.
    private var lastLegalOffset: LayoutPoint = .zero

    /// Subdivision count for enforce-mode searches when no positive grid
    /// is available to quantize the path.
    private static let gridlessSearchSteps = 64

    /// Begins a drag of `shapes`, which must be current top-level shapes
    /// of the session's cell. `grid` is the manufacturing grid used to
    /// quantize offsets; a non-positive grid disables quantization.
    public init(
        session: IncrementalDRCSession,
        shapes: [LayoutShape],
        grid: Double
    ) {
        self.session = session
        self.originalShapes = shapes
        self.draggedIDs = Set(shapes.map(\.id))
        self.grid = grid
        self.baseline = Self.involvedIdentities(
            in: session.currentResult,
            draggedIDs: self.draggedIDs
        )
    }

    /// Resolves a proposed offset from the drag origin. In observe mode
    /// (`enforce: false`) the proposal is always applied and the resulting
    /// violations are reported. In enforce mode an illegal proposal is
    /// replaced by the closest legal offset along the path from the last
    /// legal offset.
    public func propose(offset: LayoutPoint, enforce: Bool) throws -> DRDDragResolution {
        let proposal = quantized(offset)
        let proposalResult = try apply(proposal)
        if isLegal(proposalResult) {
            lastLegalOffset = proposal
            return DRDDragResolution(appliedOffset: proposal, outcome: .followed, result: proposalResult)
        }
        guard enforce else {
            return DRDDragResolution(appliedOffset: proposal, outcome: .followed, result: proposalResult)
        }

        let search = try furthestLegalStep(toward: proposal)
        let resolved = quantized(offsetAt(step: search.step, of: search.total, toward: proposal))
        let result = try apply(resolved)
        let outcome: DRDDragOutcome = search.step == 0 ? .blocked : .constrained
        lastLegalOffset = resolved
        return DRDDragResolution(appliedOffset: resolved, outcome: outcome, result: result)
    }

    /// Restores the dragged shapes to their origin and returns the
    /// resulting snapshot.
    @discardableResult
    public func cancel() throws -> LayoutDRCResult {
        try apply(.zero)
    }

    // MARK: - Legality

    private func isLegal(_ result: LayoutDRCResult) -> Bool {
        Self.involvedIdentities(in: result, draggedIDs: draggedIDs).isSubset(of: baseline)
    }

    private static func involvedIdentities(
        in result: LayoutDRCResult,
        draggedIDs: Set<UUID>
    ) -> Set<ViolationIdentity> {
        var identities: Set<ViolationIdentity> = []
        for violation in result.violations {
            let identity = ViolationIdentity(of: violation)
            if identity.involves(shapeIDs: draggedIDs) {
                identities.insert(identity)
            }
        }
        return identities
    }

    // MARK: - Enforce Search

    private struct SearchResult {
        var step: Int
        var total: Int
    }

    /// Bisects the path from `lastLegalOffset` to the (illegal) proposal
    /// for the furthest legal step. Step 0 is `lastLegalOffset`, which is
    /// legal by invariant: it was verified during this drag and nothing
    /// but the dragged shapes has moved since.
    private func furthestLegalStep(toward proposal: LayoutPoint) throws -> SearchResult {
        let span = max(
            abs(proposal.x - lastLegalOffset.x),
            abs(proposal.y - lastLegalOffset.y)
        )
        let total = grid > 0
            ? max(1, Int((span / grid).rounded(.up)))
            : Self.gridlessSearchSteps

        var lowestLegal = 0
        var lowestIllegal = total
        var verdictByOffset: [LayoutPoint: Bool] = [
            quantized(lastLegalOffset): true,
            quantized(proposal): false,
        ]
        while lowestIllegal - lowestLegal > 1 {
            let mid = (lowestLegal + lowestIllegal) / 2
            let candidate = quantized(offsetAt(step: mid, of: total, toward: proposal))
            let legal: Bool
            if let cached = verdictByOffset[candidate] {
                legal = cached
            } else {
                legal = isLegal(try apply(candidate))
                verdictByOffset[candidate] = legal
            }
            if legal {
                lowestLegal = mid
            } else {
                lowestIllegal = mid
            }
        }
        return SearchResult(step: lowestLegal, total: total)
    }

    private func offsetAt(step: Int, of total: Int, toward proposal: LayoutPoint) -> LayoutPoint {
        let t = Double(step) / Double(total)
        return LayoutPoint(
            x: lastLegalOffset.x + (proposal.x - lastLegalOffset.x) * t,
            y: lastLegalOffset.y + (proposal.y - lastLegalOffset.y) * t
        )
    }

    // MARK: - Session Application

    @discardableResult
    private func apply(_ offset: LayoutPoint) throws -> LayoutDRCResult {
        if offset == currentOffset {
            return session.currentResult
        }
        let moved = originalShapes.map { shape in
            var copy = shape
            copy.geometry = shape.geometry.translated(by: offset)
            return copy
        }
        let update = try session.apply(LayoutEditDelta(updatedShapes: moved))
        currentOffset = offset
        return update.result
    }

    private func quantized(_ offset: LayoutPoint) -> LayoutPoint {
        guard grid > 0 else { return offset }
        return LayoutPoint(
            x: (offset.x / grid).rounded() * grid,
            y: (offset.y / grid).rounded() * grid
        )
    }
}
