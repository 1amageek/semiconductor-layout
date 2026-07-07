import CryptoKit
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
/// - `minimumCut`: add the missing cut instances inside the reported
///   conductor overlap, using a via/contact definition that matches the
///   rule.
/// - `overlapShort`: displace one editable top-level participant by the
///   smallest rule-clean clearance that removes the same-layer short.
/// - `exactOverlap`: currently reported as an explicit manual repair
///   requirement; automated resize/create semantics are a separate rule
///   family milestone.
/// - `forbiddenLayer`: reported as an explicit manual repair requirement
///   because the marker source geometry must be repaired or removed.
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
        case .minimumCut:
            return try minimumCutRepair(for: violation)
        case .overlapShort:
            return try shortRepair(for: violation, shapesByID: shapesByID)
        case .disconnectedOpen:
            return .infeasible(.unsupportedKind(
                "an open needs routing — use the route tool or finish-net"
            ))
        case .exactOverlap, .forbiddenLayer, .notch, .rectOnly, .angle, .minEnclosedArea, .density, .extension, .ruleCoverage, .antenna:
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
                id: deterministicUUID(
                    kind: "enclosure-pad",
                    parts: [
                        violation.id.uuidString,
                        definition.id,
                        layer.name,
                        layer.purpose,
                    ]
                ),
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

    private struct MinimumCutRepairDefinition {
        var id: String
        var cutSize: LayoutSize
        var cutSpacing: Double
    }

    private func minimumCutRepair(for violation: LayoutViolation) throws -> LayoutRepairOutcome {
        guard let ruleID = violation.ruleID,
              let rule = tech.minimumCutRules.first(where: { LayoutDRCService().minimumCutRuleID($0) == ruleID }) else {
            return .infeasible(.missingContext("minimum-cut violation carries no known rule ID"))
        }
        guard let definition = minimumCutRepairDefinition(for: rule) else {
            return .infeasible(.missingContext("no via/contact definition matches the minimum-cut rule"))
        }
        guard let required = violation.required, let measured = violation.measured else {
            return .infeasible(.missingContext("minimum-cut violation carries no count measurement"))
        }
        let missingCount = max(1, Int(ceil(required - measured)))
        guard let netID = violation.netIDs.first else {
            return .infeasible(.missingContext("minimum-cut violation carries no net ID"))
        }
        let centers = cutCenters(
            count: missingCount,
            cutSize: definition.cutSize,
            cutSpacing: definition.cutSpacing,
            region: violation.region
        )
        guard centers.count == missingCount else {
            return .infeasible(.blockedByNeighbours)
        }
        let delta = LayoutEditDelta(addedVias: centers.enumerated().map { index, center in
            LayoutVia(
                id: deterministicUUID(
                    kind: "minimum-cut-via",
                    parts: [
                        violation.id.uuidString,
                        definition.id,
                        String(index),
                        String(describing: center.x),
                        String(describing: center.y),
                    ]
                ),
                viaDefinitionID: definition.id,
                position: center,
                netID: netID
            )
        })
        if try resolves(violation, delta: delta) {
            return .repair(LayoutRepair(
                violationID: violation.id,
                delta: delta,
                summary: "Add \(missingCount) \(definition.id) cut\(missingCount == 1 ? "" : "s") inside the conductor overlap"
            ))
        }
        return .infeasible(.blockedByNeighbours)
    }

    private struct ShortRepairCandidate {
        var shape: LayoutShape
        var offset: LayoutPoint

        var score: Double {
            hypot(offset.x, offset.y)
        }
    }

    private func shortRepair(
        for violation: LayoutViolation,
        shapesByID: [UUID: LayoutShape]
    ) throws -> LayoutRepairOutcome {
        guard violation.shapeIDs.count == 2,
              let firstID = violation.shapeIDs.first,
              let secondID = violation.shapeIDs.last else {
            return .infeasible(.missingContext("same-layer short repair needs exactly two editable shapes"))
        }
        guard let first = shapesByID[firstID],
              let second = shapesByID[secondID] else {
            return .infeasible(.childGeometry)
        }
        guard first.layer == second.layer else {
            return .infeasible(.missingContext("same-layer short repair received different layers"))
        }

        let clearance = shortRepairClearance(for: first.layer)
        let firstBounds = LayoutGeometryAnalysis.boundingBox(for: first.geometry)
        let secondBounds = LayoutGeometryAnalysis.boundingBox(for: second.geometry)
        let candidates = shortRepairCandidates(
            first: first,
            firstBounds: firstBounds,
            second: second,
            secondBounds: secondBounds,
            clearance: clearance
        )

        for candidate in candidates {
            var moved = candidate.shape
            moved.geometry = moved.geometry.translated(by: candidate.offset)
            let delta = LayoutEditDelta(updatedShapes: [moved])
            if try resolves(violation, delta: delta) {
                return .repair(LayoutRepair(
                    violationID: violation.id,
                    delta: delta,
                    summary: String(
                        format: "Move shorted shape by (%.3f, %.3f) to restore %.3f um clearance",
                        candidate.offset.x,
                        candidate.offset.y,
                        clearance
                    )
                ))
            }
        }
        return .infeasible(.blockedByNeighbours)
    }

    private func shortRepairClearance(for layer: LayoutLayerID) -> Double {
        let ruleClearance = tech.ruleSet(for: layer)?.minSpacing ?? 0
        let gridClearance = tech.grid > 0 ? tech.grid : 1e-3
        return quantizeUp(max(ruleClearance, gridClearance))
    }

    private func shortRepairCandidates(
        first: LayoutShape,
        firstBounds: LayoutRect,
        second: LayoutShape,
        secondBounds: LayoutRect,
        clearance: Double
    ) -> [ShortRepairCandidate] {
        var candidates: [ShortRepairCandidate] = []
        candidates.append(contentsOf: shortSeparationOffsets(
            moving: firstBounds,
            fixed: secondBounds,
            clearance: clearance
        ).map { ShortRepairCandidate(shape: first, offset: $0) })
        candidates.append(contentsOf: shortSeparationOffsets(
            moving: secondBounds,
            fixed: firstBounds,
            clearance: clearance
        ).map { ShortRepairCandidate(shape: second, offset: $0) })
        return candidates
            .filter { abs($0.offset.x) > 1.0e-12 || abs($0.offset.y) > 1.0e-12 }
            .sorted {
                if abs($0.score - $1.score) > 1.0e-12 {
                    return $0.score < $1.score
                }
                if abs(abs($0.offset.x) - abs($1.offset.x)) > 1.0e-12 {
                    return abs($0.offset.x) < abs($1.offset.x)
                }
                return abs($0.offset.y) < abs($1.offset.y)
            }
    }

    private func shortSeparationOffsets(
        moving: LayoutRect,
        fixed: LayoutRect,
        clearance: Double
    ) -> [LayoutPoint] {
        [
            LayoutPoint(x: fixed.minX - clearance - moving.maxX, y: 0),
            LayoutPoint(x: fixed.maxX + clearance - moving.minX, y: 0),
            LayoutPoint(x: 0, y: fixed.minY - clearance - moving.maxY),
            LayoutPoint(x: 0, y: fixed.maxY + clearance - moving.minY),
        ]
    }

    private func minimumCutRepairDefinition(for rule: LayoutMinimumCutRule) -> MinimumCutRepairDefinition? {
        for via in tech.vias where cutStackMatches(
            cutLayer: via.cutLayer,
            bottomLayer: via.bottomLayer,
            topLayer: via.topLayer,
            rule: rule
        ) {
            return MinimumCutRepairDefinition(id: via.id, cutSize: via.cutSize, cutSpacing: via.cutSpacing)
        }
        for contact in tech.contacts where cutStackMatches(
            cutLayer: contact.cutLayer,
            bottomLayer: contact.bottomLayer,
            topLayer: contact.topLayer,
            rule: rule
        ) {
            return MinimumCutRepairDefinition(id: contact.id, cutSize: contact.cutSize, cutSpacing: contact.cutSpacing)
        }
        return nil
    }

    private func cutStackMatches(
        cutLayer: LayoutLayerID,
        bottomLayer: LayoutLayerID,
        topLayer: LayoutLayerID,
        rule: LayoutMinimumCutRule
    ) -> Bool {
        guard cutLayer == rule.cutLayer else { return false }
        let sameOrientation = bottomLayer == rule.bottomLayer && topLayer == rule.topLayer
        let reversedOrientation = bottomLayer == rule.topLayer && topLayer == rule.bottomLayer
        return sameOrientation || reversedOrientation
    }

    private func cutCenters(
        count: Int,
        cutSize: LayoutSize,
        cutSpacing: Double,
        region: LayoutRect
    ) -> [LayoutPoint] {
        guard count > 0 else { return [] }
        let marginX = cutSize.width / 2
        let marginY = cutSize.height / 2
        let minX = region.minX + marginX
        let maxX = region.maxX - marginX
        let minY = region.minY + marginY
        let maxY = region.maxY - marginY
        guard minX <= maxX, minY <= maxY else { return [] }

        let pitch = max(cutSize.width, cutSize.height) + max(cutSpacing, tech.grid)
        let columns = max(1, Int(floor((maxX - minX) / pitch)) + 1)
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        guard Double(rows - 1) * pitch <= maxY - minY + 1.0e-12 else { return [] }

        var centers: [LayoutPoint] = []
        centers.reserveCapacity(count)
        let usedColumns = min(columns, count)
        let startX = clamp(region.center.x - (Double(usedColumns - 1) * pitch / 2), minX, maxX)
        let startY = clamp(region.center.y - (Double(rows - 1) * pitch / 2), minY, maxY)
        for row in 0..<rows {
            for column in 0..<columns {
                guard centers.count < count else { return centers }
                let x = clamp(startX + Double(column) * pitch, minX, maxX)
                let y = clamp(startY + Double(row) * pitch, minY, maxY)
                centers.append(LayoutPoint(x: x, y: y))
            }
        }
        return centers
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(max(value, minimum), maximum)
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

    private func deterministicUUID(kind: String, parts: [String]) -> UUID {
        let input = (["layout-repair", kind] + parts).joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
