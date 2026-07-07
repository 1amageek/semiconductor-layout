import Foundation
import LayoutCore

/// Incremental constraint checking over geometry edits to one cell.
///
/// The session indexes persisted constraint members by ID. A geometry delta
/// only recomputes constraints that reference edited shapes; all other
/// verdicts remain exact because their resolved member bounds did not change.
///
/// Deltas are absorbed into an O(delta) overlay instead of mutating a full
/// document mirror: the mirror is materialized only when an affected
/// constraint actually needs re-checking, so the common no-member-touched
/// tick costs nothing proportional to the design size.
///
/// Structural edits such as constraint CRUD, instance changes, cell
/// navigation, and child-cell edits are outside ``LayoutEditDelta`` and
/// require ``rebuild(document:cellID:)``.
public final class LiveConstraintSession {
    private let checker: LayoutConstraintChecker
    private var document: LayoutDocument
    private var cellID: UUID
    private var constraintIndicesByMemberID: [UUID: Set<Int>] = [:]
    private var violationsByConstraintIndex: [Int: [LayoutConstraintViolation]] = [:]
    private var constraintCount = 0

    // Pending overlay since the last materialization. `latestValues`
    // carries the newest shape/via value for updated or added elements;
    // additions remember their arrival order so materialization appends
    // exactly like sequential delta application would.
    private var pendingShapeValues: [UUID: LayoutShape] = [:]
    private var pendingShapeRemovals: Set<UUID> = []
    private var pendingShapeAddOrder: [UUID] = []
    private var pendingViaValues: [UUID: LayoutVia] = [:]
    private var pendingViaRemovals: Set<UUID> = []
    private var pendingViaAddOrder: [UUID] = []
    private var knownShapeIDs: Set<UUID> = []
    private var knownViaIDs: Set<UUID> = []

    public init(
        document: LayoutDocument,
        cellID: UUID,
        checker: LayoutConstraintChecker = LayoutConstraintChecker()
    ) throws {
        self.checker = checker
        self.document = document
        self.cellID = cellID
        try configure(document: document, cellID: cellID)
    }

    public var currentViolations: [LayoutConstraintViolation] {
        assembleViolations()
    }

    @discardableResult
    public func rebuild(document: LayoutDocument, cellID: UUID) throws -> [LayoutConstraintViolation] {
        try configure(document: document, cellID: cellID)
        return currentViolations
    }

    public func apply(_ delta: LayoutEditDelta) throws -> LiveConstraintUpdate {
        let editedMemberIDs = Self.editedShapeIDs(in: delta)
        var affectedIndices: Set<Int> = []
        for id in editedMemberIDs {
            if let indices = constraintIndicesByMemberID[id] {
                affectedIndices.formUnion(indices)
            }
        }

        try absorb(delta)

        guard !affectedIndices.isEmpty else {
            return LiveConstraintUpdate(
                violations: currentViolations,
                recomputedConstraintIndices: [],
                skippedConstraintCount: constraintCount
            )
        }

        try materializePendingEdits()
        let fresh = try checker.check(
            document: document,
            cellID: cellID,
            constraintIndices: affectedIndices
        )
        for index in affectedIndices {
            violationsByConstraintIndex[index] = nil
        }
        for violation in fresh {
            violationsByConstraintIndex[violation.constraintIndex, default: []].append(violation)
        }

        return LiveConstraintUpdate(
            violations: currentViolations,
            recomputedConstraintIndices: affectedIndices.sorted(),
            skippedConstraintCount: max(0, constraintCount - affectedIndices.count)
        )
    }

    private func configure(document: LayoutDocument, cellID: UUID) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        self.document = document
        self.cellID = cellID
        constraintCount = cell.constraints.count
        constraintIndicesByMemberID = Self.buildMemberIndex(for: cell.constraints)
        violationsByConstraintIndex = [:]
        pendingShapeValues = [:]
        pendingShapeRemovals = []
        pendingShapeAddOrder = []
        pendingViaValues = [:]
        pendingViaRemovals = []
        pendingViaAddOrder = []
        knownShapeIDs = Set(cell.shapes.map(\.id))
        knownViaIDs = Set(cell.vias.map(\.id))
        let violations = try checker.check(document: document, cellID: cellID)
        for violation in violations {
            violationsByConstraintIndex[violation.constraintIndex, default: []].append(violation)
        }
    }

    private func assembleViolations() -> [LayoutConstraintViolation] {
        var result: [LayoutConstraintViolation] = []
        for index in violationsByConstraintIndex.keys.sorted() {
            if let violations = violationsByConstraintIndex[index] {
                result.append(contentsOf: violations)
            }
        }
        return result
    }

    // MARK: - Overlay

    /// Validates the delta against the overlaid state and records it.
    /// O(delta): nothing here touches the cell's arrays.
    private func absorb(_ delta: LayoutEditDelta) throws {
        try delta.validateAgainstKnownElements(
            shapeIDs: knownShapeIDs,
            viaIDs: knownViaIDs
        )
        absorbShapeDelta(delta)
        absorbViaDelta(delta)
    }

    private func absorbShapeDelta(_ delta: LayoutEditDelta) {
        for shape in delta.updatedShapes {
            pendingShapeValues[shape.id] = shape
        }
        for id in delta.removedShapeIDs {
            knownShapeIDs.remove(id)
            removePendingShape(id)
        }
        for shape in delta.addedShapes {
            knownShapeIDs.insert(shape.id)
            pendingShapeAddOrder.append(shape.id)
            pendingShapeValues[shape.id] = shape
        }
    }

    private func absorbViaDelta(_ delta: LayoutEditDelta) {
        for via in delta.updatedVias {
            pendingViaValues[via.id] = via
        }
        for id in delta.removedViaIDs {
            knownViaIDs.remove(id)
            removePendingVia(id)
        }
        for via in delta.addedVias {
            knownViaIDs.insert(via.id)
            pendingViaAddOrder.append(via.id)
            pendingViaValues[via.id] = via
        }
    }

    private func removePendingShape(_ id: UUID) {
        if let addIndex = pendingShapeAddOrder.firstIndex(of: id) {
            pendingShapeAddOrder.remove(at: addIndex)
            pendingShapeValues[id] = nil
        } else {
            pendingShapeValues[id] = nil
            pendingShapeRemovals.insert(id)
        }
    }

    private func removePendingVia(_ id: UUID) {
        if let addIndex = pendingViaAddOrder.firstIndex(of: id) {
            pendingViaAddOrder.remove(at: addIndex)
            pendingViaValues[id] = nil
        } else {
            pendingViaValues[id] = nil
            pendingViaRemovals.insert(id)
        }
    }

    /// Folds the overlay into the stored document in one pass — the same
    /// final state sequential delta application would have produced:
    /// updates in place, removals dropped, additions appended in arrival
    /// order with their latest value.
    private func materializePendingEdits() throws {
        let nothingPending = pendingShapeValues.isEmpty && pendingShapeRemovals.isEmpty
            && pendingViaValues.isEmpty && pendingViaRemovals.isEmpty
        guard !nothingPending else { return }
        guard var cell = document.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }

        if !pendingShapeRemovals.isEmpty {
            cell.shapes.removeAll { pendingShapeRemovals.contains($0.id) }
        }
        if !pendingShapeValues.isEmpty {
            let added = Set(pendingShapeAddOrder)
            for index in cell.shapes.indices {
                if let updated = pendingShapeValues[cell.shapes[index].id] {
                    cell.shapes[index] = updated
                }
            }
            for id in pendingShapeAddOrder {
                guard let shape = pendingShapeValues[id], added.contains(id) else { continue }
                cell.shapes.append(shape)
            }
        }

        if !pendingViaRemovals.isEmpty {
            cell.vias.removeAll { pendingViaRemovals.contains($0.id) }
        }
        if !pendingViaValues.isEmpty {
            for index in cell.vias.indices {
                if let updated = pendingViaValues[cell.vias[index].id] {
                    cell.vias[index] = updated
                }
            }
            for id in pendingViaAddOrder {
                guard let via = pendingViaValues[id] else { continue }
                cell.vias.append(via)
            }
        }

        document.updateCell(cell)
        pendingShapeValues = [:]
        pendingShapeRemovals = []
        pendingShapeAddOrder = []
        pendingViaValues = [:]
        pendingViaRemovals = []
        pendingViaAddOrder = []
    }

    private static func buildMemberIndex(for constraints: [LayoutConstraint]) -> [UUID: Set<Int>] {
        var index: [UUID: Set<Int>] = [:]
        for (constraintIndex, constraint) in constraints.enumerated() {
            for memberID in constraint.memberIDsForIncrementalEvaluation {
                index[memberID, default: []].insert(constraintIndex)
            }
        }
        return index
    }

    private static func editedShapeIDs(in delta: LayoutEditDelta) -> Set<UUID> {
        var ids = Set<UUID>()
        for shape in delta.addedShapes { ids.insert(shape.id) }
        for shape in delta.updatedShapes { ids.insert(shape.id) }
        for id in delta.removedShapeIDs { ids.insert(id) }
        return ids
    }
}

private extension LayoutConstraint {
    var memberIDsForIncrementalEvaluation: [UUID] {
        switch self {
        case .symmetry(let constraint):
            constraint.members + constraint.selfSymmetricMembers
        case .matching(let constraint):
            constraint.members
        case .commonCentroid(let constraint):
            constraint.members
        case .interdigitated(let constraint):
            constraint.members
        case .alignment(let constraint):
            constraint.members
        }
    }
}
