import Foundation
import LayoutCore

/// Evaluates a cell's persisted design-intent constraints (symmetry,
/// matching, alignment, common centroid, interdigitation) against its
/// current geometry and reports violations, DRC-style.
///
/// Members resolve to direct shapes or instances of the checked cell;
/// an instance contributes the transformed bounding box of its referenced
/// cell hierarchy. Geometric interpretation matches the SA placement
/// engine: a `vertical` symmetry axis is a vertical line (pairs mirror in
/// x), pairs are member indices (0,1), (2,3), ..., a derived axis is the
/// mean of member centers, common-centroid groups must share the overall
/// centroid, and interdigitation order is checked along x. Matching
/// budgets apply to bounding-box dimensions: `maxWidthMismatch` to width,
/// `maxLengthMismatch` to height; a nil budget means exact within the
/// checker tolerance.
///
/// The result order is deterministic: constraints in array order, members
/// in declared order. Unresolved members and ill-formed constraints are
/// reported as violations, never skipped silently.
public struct LayoutConstraintChecker: Sendable {
    /// Geometric comparison slack; positions and dimensions deviating by
    /// no more than this are considered equal.
    public var tolerance: Double

    public init(tolerance: Double = 1e-9) {
        self.tolerance = tolerance
    }

    public func check(document: LayoutDocument, cellID: UUID) throws -> [LayoutConstraintViolation] {
        try check(document: document, cellID: cellID, constraintIndices: nil)
    }

    public func check(
        document: LayoutDocument,
        cellID: UUID,
        constraintIndices: Set<Int>
    ) throws -> [LayoutConstraintViolation] {
        try check(document: document, cellID: cellID, constraintIndices: Optional(constraintIndices))
    }

    private func check(
        document: LayoutDocument,
        cellID: UUID,
        constraintIndices: Set<Int>?
    ) throws -> [LayoutConstraintViolation] {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCoreError.cellNotFound(cellID)
        }
        var violations: [LayoutConstraintViolation] = []
        for (index, constraint) in cell.constraints.enumerated() {
            if let constraintIndices, !constraintIndices.contains(index) {
                continue
            }
            switch constraint {
            case .symmetry(let symmetry):
                checkSymmetry(symmetry, index: index, cell: cell, document: document, into: &violations)
            case .matching(let matching):
                checkMatching(matching, index: index, cell: cell, document: document, into: &violations)
            case .alignment(let alignment):
                checkAlignment(alignment, index: index, cell: cell, document: document, into: &violations)
            case .commonCentroid(let centroid):
                checkCommonCentroid(centroid, index: index, cell: cell, document: document, into: &violations)
            case .interdigitated(let interdigitated):
                checkInterdigitated(interdigitated, index: index, cell: cell, document: document, into: &violations)
            }
        }
        return violations
    }

    // MARK: - Symmetry

    private func checkSymmetry(
        _ constraint: LayoutSymmetryConstraint,
        index: Int,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) {
        let severity = severity(isHard: constraint.isHard)
        guard !constraint.members.isEmpty, constraint.members.count.isMultiple(of: 2) else {
            violations.append(LayoutConstraintViolation(
                kind: .malformedConstraint,
                constraintIndex: index,
                severity: severity,
                message: "Symmetry constraint needs a non-empty, even member list to form pairs; got \(constraint.members.count).",
                memberIDs: constraint.members
            ))
            return
        }
        guard let members = resolve(constraint.members, index: index, severity: severity, cell: cell, document: document, into: &violations),
              let axisMembers = resolve(constraint.selfSymmetricMembers, index: index, severity: severity, cell: cell, document: document, into: &violations)
        else { return }

        // Axis position: explicit, or the mean of the paired members'
        // centers along the mirrored coordinate (the SA derivation rule).
        let axisPosition: Double
        if let explicit = constraint.axisPosition {
            axisPosition = explicit
        } else {
            let coordinates = members.map { axisCoordinate($0.bounds.center, axis: constraint.axis) }
            axisPosition = coordinates.reduce(0, +) / Double(coordinates.count)
        }

        for pairStart in stride(from: 0, to: members.count, by: 2) {
            let a = members[pairStart]
            let b = members[pairStart + 1]
            let mirrorError = abs(
                axisCoordinate(a.bounds.center, axis: constraint.axis)
                    + axisCoordinate(b.bounds.center, axis: constraint.axis)
                    - 2 * axisPosition
            )
            let alongError = abs(
                alongCoordinate(a.bounds.center, axis: constraint.axis)
                    - alongCoordinate(b.bounds.center, axis: constraint.axis)
            )
            let deviation = max(mirrorError, alongError)
            if deviation > tolerance {
                violations.append(LayoutConstraintViolation(
                    kind: .symmetryPairMismatch,
                    constraintIndex: index,
                    severity: severity,
                    message: "Pair (\(pairStart), \(pairStart + 1)) does not mirror across the \(constraint.axis.rawValue) axis at \(axisPosition).",
                    region: a.bounds.union(b.bounds),
                    memberIDs: [a.id, b.id],
                    measured: deviation,
                    required: tolerance
                ))
            }
        }

        for member in axisMembers {
            let deviation = abs(axisCoordinate(member.bounds.center, axis: constraint.axis) - axisPosition)
            if deviation > tolerance {
                violations.append(LayoutConstraintViolation(
                    kind: .symmetryAxisMemberOffAxis,
                    constraintIndex: index,
                    severity: severity,
                    message: "Self-symmetric member sits off the \(constraint.axis.rawValue) axis at \(axisPosition).",
                    region: member.bounds,
                    memberIDs: [member.id],
                    measured: deviation,
                    required: tolerance
                ))
            }
        }
    }

    /// The coordinate a symmetry axis mirrors: x for a vertical axis line,
    /// y for a horizontal one.
    private func axisCoordinate(_ point: LayoutPoint, axis: LayoutSymmetryAxis) -> Double {
        axis == .vertical ? point.x : point.y
    }

    /// The coordinate running along the axis, which pairs must share.
    private func alongCoordinate(_ point: LayoutPoint, axis: LayoutSymmetryAxis) -> Double {
        axis == .vertical ? point.y : point.x
    }

    // MARK: - Matching

    private func checkMatching(
        _ constraint: LayoutMatchingConstraint,
        index: Int,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) {
        let severity = severity(isHard: constraint.isHard)
        guard constraint.members.count >= 2 else {
            violations.append(malformedGroup(constraint.members, kindName: "Matching", index: index, severity: severity))
            return
        }
        guard let members = resolve(constraint.members, index: index, severity: severity, cell: cell, document: document, into: &violations)
        else { return }

        let reference = members[0]
        let widthBudget = max(constraint.maxWidthMismatch ?? 0, tolerance)
        let lengthBudget = max(constraint.maxLengthMismatch ?? 0, tolerance)
        for member in members.dropFirst() {
            let widthError = abs(member.bounds.size.width - reference.bounds.size.width)
            if widthError > widthBudget {
                violations.append(LayoutConstraintViolation(
                    kind: .matchingWidthMismatch,
                    constraintIndex: index,
                    severity: severity,
                    message: "Member width \(member.bounds.size.width) mismatches the reference width \(reference.bounds.size.width).",
                    region: reference.bounds.union(member.bounds),
                    memberIDs: [reference.id, member.id],
                    measured: widthError,
                    required: widthBudget
                ))
            }
            let lengthError = abs(member.bounds.size.height - reference.bounds.size.height)
            if lengthError > lengthBudget {
                violations.append(LayoutConstraintViolation(
                    kind: .matchingLengthMismatch,
                    constraintIndex: index,
                    severity: severity,
                    message: "Member height \(member.bounds.size.height) mismatches the reference height \(reference.bounds.size.height).",
                    region: reference.bounds.union(member.bounds),
                    memberIDs: [reference.id, member.id],
                    measured: lengthError,
                    required: lengthBudget
                ))
            }
        }
    }

    // MARK: - Alignment

    private func checkAlignment(
        _ constraint: LayoutAlignmentConstraint,
        index: Int,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) {
        let severity = severity(isHard: constraint.isHard)
        guard constraint.members.count >= 2 else {
            violations.append(malformedGroup(constraint.members, kindName: "Alignment", index: index, severity: severity))
            return
        }
        guard let members = resolve(constraint.members, index: index, severity: severity, cell: cell, document: document, into: &violations)
        else { return }

        let reference = members[0]
        let referenceCoordinate = alignmentCoordinate(reference.bounds, mode: constraint.mode)
        let budget = max(constraint.tolerance, tolerance)
        for member in members.dropFirst() {
            let deviation = abs(alignmentCoordinate(member.bounds, mode: constraint.mode) - referenceCoordinate)
            if deviation > budget {
                violations.append(LayoutConstraintViolation(
                    kind: .alignmentMismatch,
                    constraintIndex: index,
                    severity: severity,
                    message: "Member \(constraint.mode.rawValue) deviates from the reference by \(deviation).",
                    region: reference.bounds.union(member.bounds),
                    memberIDs: [reference.id, member.id],
                    measured: deviation,
                    required: budget
                ))
            }
        }
    }

    private func alignmentCoordinate(_ bounds: LayoutRect, mode: LayoutAlignmentConstraint.Mode) -> Double {
        switch mode {
        case .minX: return bounds.minX
        case .centerX: return bounds.center.x
        case .maxX: return bounds.maxX
        case .minY: return bounds.minY
        case .centerY: return bounds.center.y
        case .maxY: return bounds.maxY
        }
    }

    // MARK: - Common centroid

    private func checkCommonCentroid(
        _ constraint: LayoutCommonCentroidConstraint,
        index: Int,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) {
        guard constraint.members.count >= 2, !constraint.pattern.isEmpty else {
            violations.append(LayoutConstraintViolation(
                kind: .malformedConstraint,
                constraintIndex: index,
                message: "Common-centroid constraint needs at least two members and a non-empty pattern.",
                memberIDs: constraint.members
            ))
            return
        }
        guard let members = resolve(constraint.members, index: index, severity: .error, cell: cell, document: document, into: &violations)
        else { return }

        // Pattern labels assign members to groups (SA semantics: the
        // pattern repeats when shorter than the member list).
        var groups: [Int: [ResolvedMember]] = [:]
        for (memberIndex, member) in members.enumerated() {
            groups[constraint.pattern[memberIndex % constraint.pattern.count], default: []].append(member)
        }
        guard groups.count >= 2 else {
            violations.append(LayoutConstraintViolation(
                kind: .malformedConstraint,
                constraintIndex: index,
                message: "Common-centroid pattern assigns every member to one group; it needs at least two.",
                memberIDs: constraint.members
            ))
            return
        }

        let overall = centroid(of: members)
        for label in groups.keys.sorted() {
            guard let groupMembers = groups[label] else { continue }
            let groupCentroid = centroid(of: groupMembers)
            let deviation = ((groupCentroid.x - overall.x) * (groupCentroid.x - overall.x)
                + (groupCentroid.y - overall.y) * (groupCentroid.y - overall.y)).squareRoot()
            if deviation > tolerance {
                violations.append(LayoutConstraintViolation(
                    kind: .centroidMismatch,
                    constraintIndex: index,
                    message: "Group \(label) centroid deviates from the common centroid by \(deviation).",
                    region: groupMembers.dropFirst().reduce(groupMembers[0].bounds) { $0.union($1.bounds) },
                    memberIDs: groupMembers.map(\.id),
                    measured: deviation,
                    required: tolerance
                ))
            }
        }
    }

    private func centroid(of members: [ResolvedMember]) -> LayoutPoint {
        let count = Double(members.count)
        return LayoutPoint(
            x: members.map(\.bounds.center.x).reduce(0, +) / count,
            y: members.map(\.bounds.center.y).reduce(0, +) / count
        )
    }

    // MARK: - Interdigitation

    private func checkInterdigitated(
        _ constraint: LayoutInterdigitatedConstraint,
        index: Int,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) {
        guard constraint.members.count >= 2, !constraint.pattern.isEmpty else {
            violations.append(LayoutConstraintViolation(
                kind: .malformedConstraint,
                constraintIndex: index,
                message: "Interdigitation constraint needs at least two members and a non-empty pattern.",
                memberIDs: constraint.members
            ))
            return
        }
        guard Set(constraint.pattern).count >= 2 else {
            violations.append(LayoutConstraintViolation(
                kind: .malformedConstraint,
                constraintIndex: index,
                message: "Interdigitation pattern assigns every member to one group; it needs at least two.",
                memberIDs: constraint.members
            ))
            return
        }
        guard let members = resolve(constraint.members, index: index, severity: .error, cell: cell, document: document, into: &violations)
        else { return }

        // Fingers interleave along x (SA semantics). Sorting is made
        // deterministic for ties by y, then by declared order.
        let label: (Int) -> Int = { constraint.pattern[$0 % constraint.pattern.count] }
        let sorted = members.enumerated().sorted { lhs, rhs in
            let a = lhs.element.bounds.center
            let b = rhs.element.bounds.center
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return lhs.offset < rhs.offset
        }
        for (position, entry) in sorted.enumerated() where label(entry.offset) != label(position) {
            violations.append(LayoutConstraintViolation(
                kind: .interdigitationOrderMismatch,
                constraintIndex: index,
                message: "Member at x-order \(position) carries pattern label \(label(entry.offset)); the pattern expects \(label(position)).",
                region: entry.element.bounds,
                memberIDs: [entry.element.id]
            ))
        }
    }

    // MARK: - Member resolution

    private struct ResolvedMember {
        var id: UUID
        var bounds: LayoutRect
    }

    /// Resolves member IDs to bounding boxes against the cell's direct
    /// shapes and instances. Reports every unresolved ID as a violation
    /// and returns nil when any member is missing, because a partial
    /// geometric verdict would be misleading.
    private func resolve(
        _ ids: [UUID],
        index: Int,
        severity: LayoutViolationSeverity,
        cell: LayoutCell,
        document: LayoutDocument,
        into violations: inout [LayoutConstraintViolation]
    ) -> [ResolvedMember]? {
        var resolved: [ResolvedMember] = []
        var missing: [UUID] = []
        for id in ids {
            if let shape = cell.shapes.first(where: { $0.id == id }) {
                resolved.append(ResolvedMember(
                    id: id,
                    bounds: LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                ))
            } else if let instance = cell.instances.first(where: { $0.id == id }),
                      let bounds = instanceBounds(instance, document: document, depth: 0) {
                resolved.append(ResolvedMember(id: id, bounds: bounds))
            } else {
                missing.append(id)
            }
        }
        guard missing.isEmpty else {
            for id in missing {
                violations.append(LayoutConstraintViolation(
                    kind: .unresolvedMember,
                    constraintIndex: index,
                    severity: severity,
                    message: "Constraint member \(id) is neither a shape nor a geometry-bearing instance of the cell.",
                    memberIDs: [id]
                ))
            }
            return nil
        }
        return resolved
    }

    /// Placed bounding box of an instance: the referenced cell hierarchy's
    /// bounds pushed through the instance transform (corner-wise, so
    /// rotation and mirroring are handled). Nil for empty hierarchies.
    private func instanceBounds(_ instance: LayoutInstance, document: LayoutDocument, depth: Int) -> LayoutRect? {
        guard depth < 10, let cell = document.cell(withID: instance.cellID) else { return nil }
        var localBounds: LayoutRect?
        for shape in cell.shapes {
            let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            localBounds = localBounds.map { $0.union(box) } ?? box
        }
        for nested in cell.instances {
            guard let box = instanceBounds(nested, document: document, depth: depth + 1) else { continue }
            localBounds = localBounds.map { $0.union(box) } ?? box
        }
        guard let localBounds else { return nil }
        return instance.occurrenceTransforms()
            .map { transformRect(localBounds, by: $0) }
            .reduce(nil as LayoutRect?) { partial, box in
                partial.map { $0.union(box) } ?? box
            }
    }

    private func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let first = transform.apply(to: LayoutPoint(x: rect.minX, y: rect.minY))
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for corner in [
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ] {
            let mapped = transform.apply(to: corner)
            minX = min(minX, mapped.x)
            maxX = max(maxX, mapped.x)
            minY = min(minY, mapped.y)
            maxY = max(maxY, mapped.y)
        }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func severity(isHard: Bool) -> LayoutViolationSeverity {
        isHard ? .error : .warning
    }

    private func malformedGroup(
        _ members: [UUID],
        kindName: String,
        index: Int,
        severity: LayoutViolationSeverity
    ) -> LayoutConstraintViolation {
        LayoutConstraintViolation(
            kind: .malformedConstraint,
            constraintIndex: index,
            severity: severity,
            message: "\(kindName) constraint needs at least two members; got \(members.count).",
            memberIDs: members
        )
    }
}
