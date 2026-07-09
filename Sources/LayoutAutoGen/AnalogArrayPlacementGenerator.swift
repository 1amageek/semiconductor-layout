import Foundation
import LayoutCore

public struct AnalogArrayPlacementGenerator: Sendable {
    public init() {}

    public func generate(
        document: LayoutDocument,
        cellID: UUID,
        request: AnalogArrayPlacementRequest
    ) throws -> AnalogArrayPlacementResult {
        let cell = try resolveCell(cellID, document: document)
        try validate(request: request)
        let memberLabels = memberPatternLabels(for: request)
        let slotLabels = try resolveSlotLabels(memberLabels: memberLabels, request: request)
        let arrangedMemberIDs = try arrangeMembersBySlotLabels(
            memberIDs: request.memberInstanceIDs,
            memberLabels: memberLabels,
            slotLabels: slotLabels
        )
        let placements = try arrangedMemberIDs.enumerated().map { slotIndex, instanceID in
            let instance = try resolveInstance(instanceID, in: cell)
            return try placedInstance(
                instance: instance,
                label: slotLabels[slotIndex],
                slotIndex: slotIndex,
                request: request,
                document: document
            )
        }
        let constraints = makeConstraints(
            memberIDs: arrangedMemberIDs,
            slotLabels: slotLabels,
            kinds: request.persistedConstraints
        )
        let boundingBox = placements.map(\.bounds).reduce(nil as LayoutRect?) { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        }
        guard let boundingBox else {
            throw AutoGenError.placementFailed("analog array placement produced no instance bounds")
        }
        try validateMatchingIfRequested(placements: placements, kinds: request.persistedConstraints)
        try validateNoPositiveOverlap(placements: placements)
        return AnalogArrayPlacementResult(
            status: "generated",
            request: request,
            arrangedMemberInstanceIDs: arrangedMemberIDs,
            slotLabels: slotLabels,
            placements: placements,
            persistedConstraints: constraints,
            boundingBox: boundingBox
        )
    }

    private func validate(request: AnalogArrayPlacementRequest) throws {
        guard request.memberInstanceIDs.count >= 2 else {
            throw AutoGenError.invalidParameter(
                device: "analogArray",
                parameter: "memberInstanceIDs",
                value: Double(request.memberInstanceIDs.count),
                reason: "analog array placement needs at least two member instances"
            )
        }
        guard Set(request.memberInstanceIDs).count == request.memberInstanceIDs.count else {
            throw AutoGenError.placementFailed("analog array members must be unique")
        }
        guard !request.pattern.isEmpty else {
            throw AutoGenError.invalidParameter(
                device: "analogArray",
                parameter: "pattern",
                value: 0,
                reason: "pattern must not be empty"
            )
        }
        guard Set(request.pattern).count >= 2 else {
            throw AutoGenError.invalidParameter(
                device: "analogArray",
                parameter: "pattern",
                value: Double(Set(request.pattern).count),
                reason: "pattern must contain at least two labels"
            )
        }
        guard request.slotPitch.width.isFinite,
              request.slotPitch.height.isFinite,
              request.slotPitch.width != 0 || request.slotPitch.height != 0 else {
            throw AutoGenError.invalidParameter(
                device: "analogArray",
                parameter: "slotPitch",
                value: max(abs(request.slotPitch.width), abs(request.slotPitch.height)),
                reason: "slot pitch must be finite and non-zero"
            )
        }
        if let slotLabels = request.slotLabels, slotLabels.count != request.memberInstanceIDs.count {
            throw AutoGenError.invalidParameter(
                device: "analogArray",
                parameter: "slotLabels",
                value: Double(slotLabels.count),
                reason: "slot label count must match member count"
            )
        }
    }

    private func memberPatternLabels(for request: AnalogArrayPlacementRequest) -> [Int] {
        request.memberInstanceIDs.indices.map { request.pattern[$0 % request.pattern.count] }
    }

    private func resolveSlotLabels(
        memberLabels: [Int],
        request: AnalogArrayPlacementRequest
    ) throws -> [Int] {
        if let slotLabels = request.slotLabels {
            try validateSlotLabels(slotLabels, memberLabels: memberLabels)
            return slotLabels
        }
        let counts = countsByLabel(memberLabels)
        var half: [Int] = []
        for label in counts.keys.sorted() {
            guard let count = counts[label], count.isMultiple(of: 2) else {
                throw AutoGenError.placementFailed(
                    "explicit slotLabels are required when pattern label \(label) has an odd member count"
                )
            }
            half.append(contentsOf: Array(repeating: label, count: count / 2))
        }
        let generated = half + half.reversed()
        try validateSlotLabels(generated, memberLabels: memberLabels)
        return generated
    }

    private func validateSlotLabels(_ slotLabels: [Int], memberLabels: [Int]) throws {
        guard countsByLabel(slotLabels) == countsByLabel(memberLabels) else {
            throw AutoGenError.placementFailed("slot label counts must match member pattern label counts")
        }
        let overall = Double(slotLabels.indices.reduce(0, +)) / Double(slotLabels.count)
        for label in Set(slotLabels).sorted() {
            let indices = slotLabels.indices.filter { slotLabels[$0] == label }
            let centroid = Double(indices.reduce(0, +)) / Double(indices.count)
            guard abs(centroid - overall) <= 1e-9 else {
                throw AutoGenError.placementFailed(
                    "slot label \(label) centroid \(centroid) does not match common centroid \(overall)"
                )
            }
        }
    }

    private func countsByLabel(_ labels: [Int]) -> [Int: Int] {
        labels.reduce(into: [:]) { counts, label in counts[label, default: 0] += 1 }
    }

    private func arrangeMembersBySlotLabels(
        memberIDs: [UUID],
        memberLabels: [Int],
        slotLabels: [Int]
    ) throws -> [UUID] {
        var queues: [Int: [UUID]] = [:]
        for (index, memberID) in memberIDs.enumerated() {
            queues[memberLabels[index], default: []].append(memberID)
        }
        var arranged: [UUID] = []
        arranged.reserveCapacity(slotLabels.count)
        for label in slotLabels {
            guard var queue = queues[label], !queue.isEmpty else {
                throw AutoGenError.placementFailed("slot label \(label) has no remaining member")
            }
            arranged.append(queue.removeFirst())
            queues[label] = queue
        }
        return arranged
    }

    private func placedInstance(
        instance: LayoutInstance,
        label: Int,
        slotIndex: Int,
        request: AnalogArrayPlacementRequest,
        document: LayoutDocument
    ) throws -> AnalogArrayPlacedInstance {
        guard instance.repetition == nil else {
            throw AutoGenError.placementFailed("instance \(instance.id) uses repetition and cannot be placed as one matched unit")
        }
        let localBounds = try referencedBounds(for: instance, document: document, depth: 0)
        var localTransform = instance.transform
        localTransform.translation = .zero
        let transformedLocalBounds = transformRect(localBounds, by: localTransform)
        let slotCenter = LayoutPoint(
            x: request.firstSlotCenter.x + Double(slotIndex) * request.slotPitch.width,
            y: request.firstSlotCenter.y + Double(slotIndex) * request.slotPitch.height
        )
        var proposed = instance.transform
        proposed.translation = LayoutPoint(
            x: slotCenter.x - transformedLocalBounds.center.x,
            y: slotCenter.y - transformedLocalBounds.center.y
        )
        let placedBounds = transformRect(localBounds, by: proposed)
        return AnalogArrayPlacedInstance(
            instanceID: instance.id,
            patternLabel: label,
            slotIndex: slotIndex,
            slotCenter: slotCenter,
            previousTransform: instance.transform,
            proposedTransform: proposed,
            bounds: placedBounds
        )
    }

    private func makeConstraints(
        memberIDs: [UUID],
        slotLabels: [Int],
        kinds: [AnalogArrayConstraintKind]
    ) -> [LayoutConstraint] {
        var constraints: [LayoutConstraint] = []
        for kind in kinds {
            switch kind {
            case .commonCentroid:
                constraints.append(.commonCentroid(LayoutCommonCentroidConstraint(
                    members: memberIDs,
                    pattern: slotLabels
                )))
            case .interdigitated:
                constraints.append(.interdigitated(LayoutInterdigitatedConstraint(
                    members: memberIDs,
                    pattern: slotLabels
                )))
            case .matching:
                constraints.append(.matching(LayoutMatchingConstraint(members: memberIDs)))
            }
        }
        return constraints
    }

    private func validateMatchingIfRequested(
        placements: [AnalogArrayPlacedInstance],
        kinds: [AnalogArrayConstraintKind]
    ) throws {
        guard kinds.contains(.matching), let reference = placements.first else {
            return
        }
        for placement in placements.dropFirst() {
            let widthMismatch = abs(placement.bounds.size.width - reference.bounds.size.width)
            let heightMismatch = abs(placement.bounds.size.height - reference.bounds.size.height)
            guard widthMismatch <= 1e-9, heightMismatch <= 1e-9 else {
                throw AutoGenError.placementFailed(
                    "matching members must have equal placed bounds before a matching constraint is persisted"
                )
            }
        }
    }

    private func validateNoPositiveOverlap(placements: [AnalogArrayPlacedInstance]) throws {
        for lhsIndex in placements.indices {
            for rhsIndex in placements.indices where rhsIndex > lhsIndex {
                let lhs = placements[lhsIndex]
                let rhs = placements[rhsIndex]
                let overlapWidth = min(lhs.bounds.maxX, rhs.bounds.maxX) - max(lhs.bounds.minX, rhs.bounds.minX)
                let overlapHeight = min(lhs.bounds.maxY, rhs.bounds.maxY) - max(lhs.bounds.minY, rhs.bounds.minY)
                guard overlapWidth <= 1e-9 || overlapHeight <= 1e-9 else {
                    throw AutoGenError.placementFailed(
                        "analog array slot pitch overlaps instances \(lhs.instanceID) and \(rhs.instanceID)"
                    )
                }
            }
        }
    }

    private func resolveCell(_ cellID: UUID, document: LayoutDocument) throws -> LayoutCell {
        guard let cell = document.cell(withID: cellID) else {
            throw AutoGenError.placementFailed("cell \(cellID) was not found")
        }
        return cell
    }

    private func resolveInstance(_ instanceID: UUID, in cell: LayoutCell) throws -> LayoutInstance {
        guard let instance = cell.instances.first(where: { $0.id == instanceID }) else {
            throw AutoGenError.placementFailed("instance \(instanceID) was not found")
        }
        return instance
    }

    private func referencedBounds(
        for instance: LayoutInstance,
        document: LayoutDocument,
        depth: Int
    ) throws -> LayoutRect {
        guard depth < 10 else {
            throw AutoGenError.placementFailed("instance hierarchy is too deep while resolving \(instance.id)")
        }
        guard let cell = document.cell(withID: instance.cellID) else {
            throw AutoGenError.placementFailed("referenced cell \(instance.cellID) was not found")
        }
        guard let bounds = try cellBounds(cell, document: document, depth: depth + 1) else {
            throw AutoGenError.placementFailed("referenced cell \(cell.id) has no geometry")
        }
        return bounds
    }

    private func cellBounds(_ cell: LayoutCell, document: LayoutDocument, depth: Int) throws -> LayoutRect? {
        var bounds: LayoutRect?
        for shape in cell.shapes {
            let shapeBounds = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            bounds = bounds.map { $0.union(shapeBounds) } ?? shapeBounds
        }
        guard depth < 10 else {
            return bounds
        }
        for nested in cell.instances {
            let nestedBounds = try referencedBounds(for: nested, document: document, depth: depth)
            let transformed = transformRect(nestedBounds, by: nested.transform)
            bounds = bounds.map { $0.union(transformed) } ?? transformed
        }
        return bounds
    }

    private func transformRect(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let corners = [
            LayoutPoint(x: rect.minX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ].map { transform.apply(to: $0) }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }
}
