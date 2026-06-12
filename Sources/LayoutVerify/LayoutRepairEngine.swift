import Foundation
import LayoutCore
import LayoutTech

/// Computes verified repairs for DRC violations.
///
/// Strategy per kind:
/// - `minSpacing`: displace one participating top-level shape along the
///   axis of least movement by the clearance deficit (grid-rounded up),
///   trying both shapes and both directions; the first candidate that
///   resolves the violation without creating new error-class violations
///   wins.
/// - `minWidth` / `minArea`: grow the rect symmetrically to the required
///   width (and length for area), same verification.
/// - `enclosure`: add landing pads (cut size + enclosure + one grid step)
///   on the via's top and bottom layers.
/// - everything else: infeasible with the manual path named.
///
/// Every candidate is validated against a private incremental-DRC mirror
/// before being offered; the engine never returns an unverified delta.
public struct LayoutRepairEngine {
    private let tech: LayoutTechDatabase
    private let document: LayoutDocument
    private let cellID: UUID
    /// The pre-repair violation set, computed once: every candidate is
    /// judged against the same baseline.
    private let baselineViolations: [LayoutViolation]

    public init(document: LayoutDocument, tech: LayoutTechDatabase, cellID: UUID) {
        self.document = document
        self.tech = tech
        self.cellID = cellID
        self.baselineViolations = LayoutDRCService()
            .run(document: document, tech: tech, cellID: cellID)
            .violations
    }

    /// Computes a verified repair for `violation`, or the reason none
    /// exists.
    public func repair(for violation: LayoutViolation) throws -> LayoutRepairOutcome {
        guard let cell = document.cell(withID: cellID) else {
            throw IncrementalDRCSessionError.targetCellNotFound
        }
        let shapesByID = Dictionary(
            cell.shapes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        switch violation.kind {
        case .minSpacing:
            return try spacingRepair(for: violation, shapesByID: shapesByID)
        case .minWidth, .minArea:
            return try growthRepair(for: violation, shapesByID: shapesByID)
        case .enclosure:
            return try enclosureRepair(for: violation)
        case .overlapShort:
            return .infeasible(.unsupportedKind(
                "a short needs a cut or a reroute — use subtract or finish-net"
            ))
        case .disconnectedOpen:
            return .infeasible(.unsupportedKind(
                "an open needs routing — use the route tool or finish-net"
            ))
        case .notch, .minEnclosedArea, .density, .ruleCoverage, .antenna:
            return .infeasible(.unsupportedKind(
                "no automated strategy for \(violation.kind.rawValue) yet"
            ))
        }
    }

    /// Applies repairs until no repairable violation remains, the budget
    /// runs out, or a round fixes nothing (oscillation guard). Returns
    /// the applied summaries and every residual violation with its
    /// infeasibility reason. The caller owns applying the deltas — this
    /// sweep SIMULATES on a working copy and returns one combined delta
    /// per applied repair in order.
    public func sweep(budget: Int = 64) throws -> (repairs: [LayoutRepair], sweep: LayoutRepairSweep) {
        var working = document
        var applied: [LayoutRepair] = []
        var summaries: [String] = []

        for _ in 0..<budget {
            let engine = LayoutRepairEngine(document: working, tech: tech, cellID: cellID)
            let violations = LayoutDRCService()
                .run(document: working, tech: tech, cellID: cellID)
                .violations
            guard let next = try engine.firstRepairable(in: violations) else {
                let residuals = try engine.residualReasons(in: violations)
                return (
                    applied,
                    LayoutRepairSweep(
                        appliedSummaries: summaries,
                        residuals: residuals,
                        reachedFixedPoint: true
                    )
                )
            }
            try Self.apply(next.delta, to: &working, cellID: cellID)
            applied.append(next)
            summaries.append(next.summary)
        }

        let violations = LayoutDRCService()
            .run(document: working, tech: tech, cellID: cellID)
            .violations
        let engine = LayoutRepairEngine(document: working, tech: tech, cellID: cellID)
        return (
            applied,
            LayoutRepairSweep(
                appliedSummaries: summaries,
                residuals: try engine.residualReasons(in: violations),
                reachedFixedPoint: false
            )
        )
    }

    private func firstRepairable(in violations: [LayoutViolation]) throws -> LayoutRepair? {
        for violation in violations {
            if case .repair(let repair) = try repair(for: violation) {
                return repair
            }
        }
        return nil
    }

    private func residualReasons(
        in violations: [LayoutViolation]
    ) throws -> [(violation: LayoutViolation, reason: LayoutRepairInfeasibility)] {
        var residuals: [(LayoutViolation, LayoutRepairInfeasibility)] = []
        for violation in violations {
            switch try repair(for: violation) {
            case .repair:
                continue
            case .infeasible(let reason):
                residuals.append((violation, reason))
            }
        }
        return residuals
    }

    // MARK: - Strategies

    private func spacingRepair(
        for violation: LayoutViolation,
        shapesByID: [UUID: LayoutShape]
    ) throws -> LayoutRepairOutcome {
        let participants = violation.shapeIDs.compactMap { shapesByID[$0] }
        guard !participants.isEmpty else {
            return violation.shapeIDs.isEmpty
                ? .infeasible(.missingContext("spacing violation carries no shape IDs"))
                : .infeasible(.childGeometry)
        }
        guard let required = violation.required, let measured = violation.measured else {
            return .infeasible(.missingContext("spacing violation carries no measurement"))
        }
        let deficit = quantizeUp(required - measured)
        guard deficit > 0 else {
            return .infeasible(.missingContext("spacing deficit is not positive"))
        }

        // Try moving each participating shape along ±x/±y, smallest
        // displacement first; offer the first verified candidate.
        let offsets = [
            LayoutPoint(x: deficit, y: 0),
            LayoutPoint(x: -deficit, y: 0),
            LayoutPoint(x: 0, y: deficit),
            LayoutPoint(x: 0, y: -deficit),
        ]
        for shape in participants {
            for offset in offsets {
                var moved = shape
                moved.geometry = shape.geometry.translated(by: offset)
                let delta = LayoutEditDelta(updatedShapes: [moved])
                if try resolves(violation, delta: delta) {
                    return .repair(LayoutRepair(
                        violationID: violation.id,
                        delta: delta,
                        summary: String(
                            format: "Move shape by (%.3f, %.3f) to restore %.3f um spacing",
                            offset.x, offset.y, required
                        )
                    ))
                }
            }
        }
        return .infeasible(.blockedByNeighbours)
    }

    private func growthRepair(
        for violation: LayoutViolation,
        shapesByID: [UUID: LayoutShape]
    ) throws -> LayoutRepairOutcome {
        guard let shapeID = violation.shapeIDs.first else {
            return .infeasible(.missingContext("violation carries no shape IDs"))
        }
        guard let shape = shapesByID[shapeID] else {
            return .infeasible(.childGeometry)
        }
        guard case .rect(let rect) = shape.geometry else {
            return .infeasible(.nonRectangularGeometry)
        }
        guard let rules = tech.ruleSet(for: shape.layer) else {
            return .infeasible(.missingContext("layer has no rule set"))
        }

        var width = rect.size.width
        var height = rect.size.height
        let minimum = rules.minWidth
        if violation.kind == .minWidth {
            if width < minimum { width = quantizeUp(minimum) }
            if height < minimum { height = quantizeUp(minimum) }
        } else {
            // Grow the SHORT side first to satisfy area with the least
            // footprint change; fall back to growing the long side.
            let area = rules.minArea
            if width * height < area {
                let shortIsWidth = width <= height
                if shortIsWidth {
                    width = quantizeUp(area / height)
                } else {
                    height = quantizeUp(area / width)
                }
            }
        }
        guard width != rect.size.width || height != rect.size.height else {
            return .infeasible(.missingContext("geometry already satisfies the rule"))
        }
        var grown = shape
        grown.geometry = .rect(LayoutRect(
            origin: LayoutPoint(
                x: rect.center.x - width / 2,
                y: rect.center.y - height / 2
            ),
            size: LayoutSize(width: width, height: height)
        ))
        let delta = LayoutEditDelta(updatedShapes: [grown])
        if try resolves(violation, delta: delta) {
            return .repair(LayoutRepair(
                violationID: violation.id,
                delta: delta,
                summary: String(
                    format: "Grow shape to %.3f x %.3f um", width, height
                )
            ))
        }
        return .infeasible(.blockedByNeighbours)
    }

    private func enclosureRepair(for violation: LayoutViolation) throws -> LayoutRepairOutcome {
        guard let viaID = violation.viaIDs.first,
              let cell = document.cell(withID: cellID),
              let via = cell.vias.first(where: { $0.id == viaID }) else {
            return .infeasible(.missingContext("enclosure violation carries no editable via"))
        }
        guard let definition = tech.viaDefinition(for: via.viaDefinitionID) else {
            return .infeasible(.missingContext("unknown via definition"))
        }
        let margin = tech.grid > 0 ? tech.grid : 1e-3
        func pad(layer: LayoutLayerID, enclosure: Double) -> LayoutShape {
            let total = enclosure + margin
            let width = definition.cutSize.width + 2 * total
            let height = definition.cutSize.height + 2 * total
            return LayoutShape(
                layer: layer,
                netID: via.netID,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(
                        x: via.position.x - width / 2,
                        y: via.position.y - height / 2
                    ),
                    size: LayoutSize(width: width, height: height)
                ))
            )
        }
        let delta = LayoutEditDelta(addedShapes: [
            pad(layer: definition.topLayer, enclosure: definition.enclosure.top),
            pad(layer: definition.bottomLayer, enclosure: definition.enclosure.bottom),
        ])
        if try resolves(violation, delta: delta) {
            return .repair(LayoutRepair(
                violationID: violation.id,
                delta: delta,
                summary: "Add landing pads on \(definition.topLayer.name) and \(definition.bottomLayer.name)"
            ))
        }
        return .infeasible(.blockedByNeighbours)
    }

    // MARK: - Verification

    /// A candidate repairs the violation iff, applied to a mirror, the
    /// violation disappears, the total count strictly decreases, and no
    /// NEW violation identity appears.
    private func resolves(
        _ violation: LayoutViolation,
        delta: LayoutEditDelta
    ) throws -> Bool {
        var mirror = document
        try Self.apply(delta, to: &mirror, cellID: cellID)
        let service = LayoutDRCService()
        let before = baselineViolations
        let after = service.run(document: mirror, tech: tech, cellID: cellID).violations
        guard after.count < before.count else { return false }
        let beforeIdentities = Set(before.map(ViolationIdentity.init))
        let target = ViolationIdentity(of: violation)
        guard !after.contains(where: { ViolationIdentity(of: $0) == target }) else { return false }
        return after.allSatisfy { beforeIdentities.contains(ViolationIdentity(of: $0)) }
    }

    private static func apply(
        _ delta: LayoutEditDelta,
        to document: inout LayoutDocument,
        cellID: UUID
    ) throws {
        guard var cell = document.cell(withID: cellID) else {
            throw IncrementalDRCSessionError.targetCellNotFound
        }
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw IncrementalDRCSessionError.unknownShapeID(shape.id)
            }
            cell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            let removed = Set(delta.removedShapeIDs)
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        cell.vias.append(contentsOf: delta.addedVias)
        document.updateCell(cell)
    }

    private func quantizeUp(_ value: Double) -> Double {
        let grid = tech.grid > 0 ? tech.grid : 1e-3
        return (value / grid).rounded(.up) * grid
    }
}
