import CryptoKit
import Foundation
import LayoutCore
import LayoutTech

public enum HeadlessFinishNetPlannerError: Error, Sendable, Equatable {
    case targetCellNotFound(UUID)
    case invalidRouteWidth(Double)
    case netAlreadyConnected(UUID)
    case routeWindowMiss(UUID)
    case routeBlocked(UUID, [LayoutViolation])
    case routeShapeIDCollision(UUID)
    case duplicateRouteShapeID(UUID)
    case routeDidNotReduceOpen(netID: UUID, opensBefore: Int, opensAfter: Int)
    case routeRegressed(netID: UUID, violations: [LayoutViolation])
}

public struct HeadlessFinishNetPlan: Sendable, Equatable {
    public let netID: UUID
    public let layer: LayoutLayerID
    public let delta: LayoutEditDelta
    public let routeShapeIDs: [UUID]
    public let opensBefore: Int
    public let opensAfter: Int
    public let shortsBefore: Int
    public let shortsAfter: Int
    public let violationCountBefore: Int
    public let violationCountAfter: Int
    public let errorCountAfter: Int
    public let warningCountAfter: Int
    public let violationsAfter: [LayoutViolation]

    public init(
        netID: UUID,
        layer: LayoutLayerID,
        delta: LayoutEditDelta,
        routeShapeIDs: [UUID],
        opensBefore: Int,
        opensAfter: Int,
        shortsBefore: Int,
        shortsAfter: Int,
        violationCountBefore: Int,
        violationCountAfter: Int,
        errorCountAfter: Int,
        warningCountAfter: Int,
        violationsAfter: [LayoutViolation]
    ) {
        self.netID = netID
        self.layer = layer
        self.delta = delta
        self.routeShapeIDs = routeShapeIDs
        self.opensBefore = opensBefore
        self.opensAfter = opensAfter
        self.shortsBefore = shortsBefore
        self.shortsAfter = shortsAfter
        self.violationCountBefore = violationCountBefore
        self.violationCountAfter = violationCountAfter
        self.errorCountAfter = errorCountAfter
        self.warningCountAfter = warningCountAfter
        self.violationsAfter = violationsAfter
    }
}

public struct HeadlessFinishNetPlanner: Sendable {
    public let windowMargin: Double

    private struct PlanningContext {
        let targetCell: LayoutCell
        let extractor: LayoutConnectivityExtractor
        let analysisBefore: ConnectivityAnalysis
        let open: ConnectivityOpen
        let flyline: Flyline
        let drcBefore: LayoutDRCResult
        let beforeIdentities: Set<ViolationIdentity>
        let effectiveWidth: Double
        let spacing: Double
        let routeWindow: LayoutRect
        let targetRegion: [LayoutRect]
    }

    private struct CandidateEvaluation {
        let candidateDocument: LayoutDocument
        let analysisAfter: ConnectivityAnalysis
        let opensBefore: Int
        let opensAfter: Int
    }

    public init(windowMargin: Double = 2.0) {
        self.windowMargin = windowMargin
    }

    public func plan(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID,
        netID: UUID,
        layer: LayoutLayerID,
        width: Double?,
        shapeIDSeed: String
    ) throws -> HeadlessFinishNetPlan {
        let context = try makePlanningContext(
            document: document,
            tech: tech,
            cellID: cellID,
            netID: netID,
            layer: layer,
            width: width
        )
        let delta = try makeRouteDelta(
            document: document,
            tech: tech,
            cellID: cellID,
            netID: netID,
            layer: layer,
            shapeIDSeed: shapeIDSeed,
            context: context
        )
        let evaluation = try evaluateCandidate(
            delta: delta,
            document: document,
            tech: tech,
            cellID: cellID,
            netID: netID,
            context: context
        )
        let drcAfter = LayoutDRCService().run(document: evaluation.candidateDocument, tech: tech, cellID: cellID)
        try validateNoRegressions(drcAfter: drcAfter, context: context, netID: netID)

        return makePlan(
            netID: netID,
            layer: layer,
            delta: delta,
            context: context,
            evaluation: evaluation,
            drcAfter: drcAfter
        )
    }

    private func makePlanningContext(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID,
        netID: UUID,
        layer: LayoutLayerID,
        width: Double?
    ) throws -> PlanningContext {
        let targetCell = try requireTargetCell(document: document, cellID: cellID)
        let extractor = LayoutConnectivityExtractor()
        let analysisBefore = try extractor.extract(document: document, tech: tech, cellID: cellID)
        guard let open = analysisBefore.opens.first(where: { $0.netID == netID }),
              let flyline = open.flylines.first else {
            throw HeadlessFinishNetPlannerError.netAlreadyConnected(netID)
        }
        let drcBefore = LayoutDRCService().run(document: document, tech: tech, cellID: cellID)
        let effectiveWidth = try validatedRouteWidth(width, layer: layer, tech: tech)
        let routeWindow = routeWindow(start: flyline.start, end: flyline.end)
        return PlanningContext(
            targetCell: targetCell,
            extractor: extractor,
            analysisBefore: analysisBefore,
            open: open,
            flyline: flyline,
            drcBefore: drcBefore,
            beforeIdentities: Set(drcBefore.violations.map(ViolationIdentity.init)),
            effectiveWidth: effectiveWidth,
            spacing: tech.ruleSet(for: layer)?.minSpacing ?? 0,
            routeWindow: routeWindow,
            targetRegion: targetRegion(for: open, flyline: flyline, layer: layer)
        )
    }

    private func makeRouteDelta(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID,
        netID: UUID,
        layer: LayoutLayerID,
        shapeIDSeed: String,
        context: PlanningContext
    ) throws -> LayoutEditDelta {
        let path = RouteAutoCompleter().findPath(RouteAutoCompleter.Request(
            start: context.flyline.start,
            target: context.flyline.end,
            window: context.routeWindow,
            obstacles: obstacles(in: context.analysisBefore, netID: netID, layer: layer, window: context.routeWindow),
            clearance: context.effectiveWidth / 2 + context.spacing,
            step: max(tech.grid, 0.01),
            targetRegion: context.targetRegion
        ))
        guard let path else {
            throw HeadlessFinishNetPlannerError.routeWindowMiss(netID)
        }
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cellID,
            tech: tech,
            start: RouteAnchor(point: context.flyline.start, layer: layer, netID: netID),
            mode: .manual,
            width: context.effectiveWidth
        )
        let preview = try session.proposePath(Array(path.dropFirst()))
        guard preview.isLegal else {
            throw HeadlessFinishNetPlannerError.routeBlocked(netID, preview.violations)
        }
        return try deterministicAddedShapeIDs(
            in: session.commit(),
            seed: shapeIDSeed,
            existingShapeIDs: Set(context.targetCell.shapes.map(\.id))
        )
    }

    private func evaluateCandidate(
        delta: LayoutEditDelta,
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID,
        netID: UUID,
        context: PlanningContext
    ) throws -> CandidateEvaluation {
        let candidateDocument = try apply(delta: delta, to: document, cellID: cellID)
        let analysisAfter = try context.extractor.extract(document: candidateDocument, tech: tech, cellID: cellID)
        let opensBefore = context.analysisBefore.flylines.count { $0.netID == netID }
        let opensAfter = analysisAfter.flylines.count { $0.netID == netID }
        guard opensAfter < opensBefore else {
            throw HeadlessFinishNetPlannerError.routeDidNotReduceOpen(
                netID: netID,
                opensBefore: opensBefore,
                opensAfter: opensAfter
            )
        }
        return CandidateEvaluation(
            candidateDocument: candidateDocument,
            analysisAfter: analysisAfter,
            opensBefore: opensBefore,
            opensAfter: opensAfter
        )
    }

    private func validateNoRegressions(
        drcAfter: LayoutDRCResult,
        context: PlanningContext,
        netID: UUID
    ) throws {
        let regressions = drcAfter.violations.filter { violation in
            guard !context.beforeIdentities.contains(ViolationIdentity(of: violation)) else {
                return false
            }
            return !(violation.kind == .disconnectedOpen && violation.netIDs == [netID])
        }
        guard regressions.isEmpty else {
            throw HeadlessFinishNetPlannerError.routeRegressed(netID: netID, violations: regressions)
        }
    }

    private func makePlan(
        netID: UUID,
        layer: LayoutLayerID,
        delta: LayoutEditDelta,
        context: PlanningContext,
        evaluation: CandidateEvaluation,
        drcAfter: LayoutDRCResult
    ) -> HeadlessFinishNetPlan {
        HeadlessFinishNetPlan(
            netID: netID,
            layer: layer,
            delta: delta,
            routeShapeIDs: delta.addedShapes.map(\.id),
            opensBefore: evaluation.opensBefore,
            opensAfter: evaluation.opensAfter,
            shortsBefore: context.analysisBefore.shorts.count,
            shortsAfter: evaluation.analysisAfter.shorts.count,
            violationCountBefore: context.drcBefore.violations.count,
            violationCountAfter: drcAfter.violations.count,
            errorCountAfter: drcAfter.violations.filter { $0.severity == .error }.count,
            warningCountAfter: drcAfter.violations.filter { $0.severity == .warning }.count,
            violationsAfter: drcAfter.violations
        )
    }

    private func requireTargetCell(document: LayoutDocument, cellID: UUID) throws -> LayoutCell {
        guard let cell = document.cell(withID: cellID) else {
            throw HeadlessFinishNetPlannerError.targetCellNotFound(cellID)
        }
        return cell
    }

    private func validatedRouteWidth(
        _ width: Double?,
        layer: LayoutLayerID,
        tech: LayoutTechDatabase
    ) throws -> Double {
        let effectiveWidth = width ?? tech.ruleSet(for: layer)?.minWidth ?? 0.1
        guard effectiveWidth.isFinite && effectiveWidth > 0 else {
            throw HeadlessFinishNetPlannerError.invalidRouteWidth(effectiveWidth)
        }
        return effectiveWidth
    }

    private func targetRegion(
        for open: ConnectivityOpen,
        flyline: Flyline,
        layer: LayoutLayerID
    ) -> [LayoutRect] {
        guard open.islands.indices.contains(flyline.toIslandIndex) else {
            return []
        }
        return open.islands[flyline.toIslandIndex].memberFootprints
            .filter { $0.layer == layer }
            .map(\.boundingBox)
    }

    private func routeWindow(start: LayoutPoint, end: LayoutPoint) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: min(start.x, end.x) - windowMargin,
                y: min(start.y, end.y) - windowMargin
            ),
            size: LayoutSize(
                width: abs(start.x - end.x) + 2 * windowMargin,
                height: abs(start.y - end.y) + 2 * windowMargin
            )
        )
    }

    private func obstacles(
        in analysis: ConnectivityAnalysis,
        netID: UUID,
        layer: LayoutLayerID,
        window: LayoutRect
    ) -> [LayoutRect] {
        analysis.nets
            .filter { !$0.declaredNetIDs.contains(netID) }
            .flatMap(\.memberFootprints)
            .filter { $0.layer == layer }
            .map(\.boundingBox)
            .filter { $0.intersects(window) }
    }

    private func apply(
        delta: LayoutEditDelta,
        to document: LayoutDocument,
        cellID: UUID
    ) throws -> LayoutDocument {
        var copy = document
        guard var cell = copy.cell(withID: cellID) else {
            throw HeadlessFinishNetPlannerError.targetCellNotFound(cellID)
        }
        for shape in delta.updatedShapes {
            guard let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) else {
                throw LayoutCoreError.shapeNotFound(shape.id)
            }
            cell.shapes[index] = shape
        }
        if !delta.removedShapeIDs.isEmpty {
            let existing = Set(cell.shapes.map(\.id))
            for id in delta.removedShapeIDs where !existing.contains(id) {
                throw LayoutCoreError.shapeNotFound(id)
            }
            let removed = Set(delta.removedShapeIDs)
            cell.shapes.removeAll { removed.contains($0.id) }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        for via in delta.updatedVias {
            guard let index = cell.vias.firstIndex(where: { $0.id == via.id }) else {
                throw LayoutCoreError.viaNotFound(via.id)
            }
            cell.vias[index] = via
        }
        if !delta.removedViaIDs.isEmpty {
            let existing = Set(cell.vias.map(\.id))
            for id in delta.removedViaIDs where !existing.contains(id) {
                throw LayoutCoreError.viaNotFound(id)
            }
            let removed = Set(delta.removedViaIDs)
            cell.vias.removeAll { removed.contains($0.id) }
        }
        cell.vias.append(contentsOf: delta.addedVias)
        copy.updateCell(cell)
        return copy
    }

    private func deterministicAddedShapeIDs(
        in delta: LayoutEditDelta,
        seed: String,
        existingShapeIDs: Set<UUID>
    ) throws -> LayoutEditDelta {
        var routeShapeIDs: Set<UUID> = []
        let addedShapes = try delta.addedShapes.enumerated().map { index, shape in
            let routeShapeID = deterministicShapeID(seed: seed, index: index, shape: shape)
            guard !existingShapeIDs.contains(routeShapeID) else {
                throw HeadlessFinishNetPlannerError.routeShapeIDCollision(routeShapeID)
            }
            guard routeShapeIDs.insert(routeShapeID).inserted else {
                throw HeadlessFinishNetPlannerError.duplicateRouteShapeID(routeShapeID)
            }
            var copy = shape
            copy = LayoutShape(
                id: routeShapeID,
                layer: shape.layer,
                netID: shape.netID,
                geometry: shape.geometry,
                properties: shape.properties
            )
            return copy
        }
        return LayoutEditDelta(
            addedShapes: addedShapes,
            updatedShapes: delta.updatedShapes,
            removedShapeIDs: delta.removedShapeIDs,
            addedVias: delta.addedVias,
            updatedVias: delta.updatedVias,
            removedViaIDs: delta.removedViaIDs
        )
    }

    private func deterministicShapeID(seed: String, index: Int, shape: LayoutShape) -> UUID {
        let parts = [
            "headless-finish-net-shape",
            seed,
            "index=\(index)",
            "layer=\(shape.layer.name):\(shape.layer.purpose)",
            "net=\(shape.netID?.uuidString ?? "")",
            "geometry=\(shape.geometry)",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
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
