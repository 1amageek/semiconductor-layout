import Foundation
import LayoutCore
import LayoutTech

public enum InteractiveRouteSessionError: Error, Equatable, Sendable {
    case targetCellNotFound
    case missingLayerRule(LayoutLayerID)
    /// No via definition in the technology connects the two layers.
    case noViaBetweenLayers(LayoutLayerID, LayoutLayerID)
    /// Inserting the layer-switch via at the current legal end would
    /// create the carried violations; the switch is rolled back.
    case viaPlacementBlocked([LayoutViolation])
}

/// DRC-enforced interactive routing over a private incremental-DRC mirror.
///
/// The session previews a route as it is drawn: every tick re-verifies the
/// candidate geometry against the design and either accepts the requested
/// end, pushes same-layer neighbours out of the way (`.shove`), or stops
/// at the last legal position (`.manual`). `switchLayer` freezes the
/// current leg, drops a via with its landing pads, and continues on the
/// new layer; `proposePath` accepts an externally computed polyline (the
/// auto-complete search) under the same all-or-nothing legality contract.
///
/// The document is never touched: `commit()` returns one delta with every
/// added shape and via plus the final positions of shoved neighbours
/// (ID-preserving updates), to be fed through the editor's single edit
/// stream as one undo unit.
public struct InteractiveRouteSession {
    private let tech: LayoutTechDatabase
    private let mode: RouteMode
    /// Requested wire width; nil falls back to the layer's minimum width.
    /// A sub-minimum request is not clamped — the DRC enforcement makes
    /// the resulting width violation visible instead.
    private let requestedWidth: Double?
    /// Same-net snapping capture radius in microns.
    private let snapRadius: Double
    /// Maximum number of neighbour pushes one shove resolution may chain.
    private let shoveBudget: Int

    private var drc: IncrementalDRCSession
    private let baselineViolationIDs: Set<ViolationIdentity>

    /// Current leg start; advances on layer switches and segment chaining.
    private var anchor: RouteAnchor
    /// Frozen legs and landing pads from completed layer legs.
    private var fixedShapes: [LayoutShape] = []
    private var fixedVias: [LayoutVia] = []
    /// The in-flight leg, replaced on every tick.
    private var legShapes: [LayoutShape] = []
    /// Shoved neighbours: original value (for rollback) and current value.
    private var pushedOriginals: [UUID: LayoutShape] = [:]
    private var pushedCurrent: [UUID: LayoutShape] = [:]

    /// Same-net snap targets on the anchor layer.
    private var snapPins: [LayoutPin] = []
    private var snapBoxes: [LayoutRect] = []
    /// Top-level shapes by ID — the shove candidates. Child occurrences
    /// cannot be moved through a delta, so they are never pushable.
    private var topShapesByID: [UUID: LayoutShape] = [:]
    private var routeNetShapes: [LayoutShape] = []
    private var routeNetPins: [LayoutPin] = []

    private var lastPreview: RoutePreview

    public init(
        document: LayoutDocument,
        cellID: UUID,
        tech: LayoutTechDatabase,
        start: RouteAnchor,
        mode: RouteMode = .manual,
        width: Double? = nil,
        snapRadius: Double = 0.25,
        shoveBudget: Int = 8
    ) throws {
        guard let cell = document.cell(withID: cellID) else {
            throw InteractiveRouteSessionError.targetCellNotFound
        }
        self.tech = tech
        self.anchor = start
        self.mode = mode
        self.requestedWidth = width
        self.snapRadius = snapRadius
        self.shoveBudget = shoveBudget
        self.drc = try IncrementalDRCSession(document: document, tech: tech, cellID: cellID)
        self.baselineViolationIDs = Set(drc.currentResult.violations.map(ViolationIdentity.init))
        self.lastPreview = RoutePreview(
            mode: mode,
            requestedEnd: start.point,
            legalEnd: start.point,
            snapReason: .none,
            delta: LayoutEditDelta()
        )

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var conflicts: [LayoutDRCService.TerminalConnectivityConflict] = []
        LayoutDRCService().flatten(
            cell: cell,
            document: document,
            tech: tech,
            transforms: [],
            terminalNetIDs: [:],
            shapes: &shapes,
            vias: &vias,
            pins: &pins,
            terminalConflicts: &conflicts
        )
        for shape in cell.shapes {
            topShapesByID[shape.id] = shape
        }
        if let netID = start.netID {
            routeNetShapes = shapes.filter { $0.netID == netID }
            routeNetPins = pins.filter { $0.netID == netID }
        } else {
            routeNetShapes = []
            routeNetPins = []
        }
        refreshSnapTargets()
    }

    public var currentAnchor: RouteAnchor { anchor }

    // MARK: - Ticks

    public mutating func tick(to point: LayoutPoint) throws -> RoutePreview {
        let snapped = snap(point)
        let requested = try evaluate(leg: routeShapes(to: snapped.point))
        if requested.newViolations.isEmpty {
            lastPreview = preview(
                requestedEnd: snapped.point,
                legalEnd: snapped.point,
                snapReason: snapped.reason
            )
            return lastPreview
        }

        if mode == .shove,
           try shoveResolve(blocking: requested.newViolations) {
            lastPreview = preview(
                requestedEnd: snapped.point,
                legalEnd: snapped.point,
                snapReason: snapped.reason
            )
            return lastPreview
        }

        // Stop short: bisect along the anchor→request parameterization for
        // the furthest legal end.
        var low = anchor.point
        var high = snapped.point
        var lastLegalShapes = try evaluate(leg: routeShapes(to: low)).shapes
        for _ in 0..<14 {
            let mid = LayoutPoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2)
            let candidate = try evaluate(leg: routeShapes(to: mid))
            if candidate.newViolations.isEmpty {
                low = mid
                lastLegalShapes = candidate.shapes
            } else {
                high = mid
            }
        }
        if legShapes.map(\.id) != lastLegalShapes.map(\.id) {
            _ = try applyLeg(lastLegalShapes)
        }
        lastPreview = preview(
            requestedEnd: snapped.point,
            legalEnd: low,
            snapReason: snapped.reason,
            stopReason: .blockedByViolations(requested.newViolations),
            violations: requested.newViolations
        )
        return lastPreview
    }

    /// Accepts an externally computed polyline for the current leg — the
    /// auto-complete path. All-or-nothing: a proposal that would create
    /// violations is rolled back and reported, never partially kept.
    public mutating func proposePath(_ points: [LayoutPoint]) throws -> RoutePreview {
        guard let end = points.last else { return lastPreview }
        let previousLeg = legShapes
        let shapes = polylineShapes(through: [anchor.point] + points)
        let outcome = try evaluate(leg: shapes)
        if outcome.newViolations.isEmpty {
            lastPreview = preview(requestedEnd: end, legalEnd: end, snapReason: .none)
            return lastPreview
        }
        _ = try applyLeg(previousLeg)
        lastPreview = preview(
            requestedEnd: end,
            legalEnd: lastPreview.legalEnd,
            snapReason: .none,
            stopReason: .blockedByViolations(outcome.newViolations),
            violations: outcome.newViolations
        )
        return lastPreview
    }

    // MARK: - Layer switching

    /// Freezes the current leg at its legal end, inserts a via with its
    /// landing pads there, and re-anchors on the new layer. Throws (and
    /// rolls back) when no via connects the layers or the via geometry
    /// would itself violate.
    public mutating func switchLayer(to newLayer: LayoutLayerID) throws -> RoutePreview {
        guard newLayer != anchor.layer else { return lastPreview }
        guard let viaDef = tech.vias.first(where: {
            ($0.topLayer == newLayer && $0.bottomLayer == anchor.layer)
                || ($0.topLayer == anchor.layer && $0.bottomLayer == newLayer)
        }) else {
            throw InteractiveRouteSessionError.noViaBetweenLayers(anchor.layer, newLayer)
        }

        let junction = lastPreview.legalEnd
        let frozenLeg = routeShapes(to: junction)
        let via = LayoutVia(
            viaDefinitionID: viaDef.id,
            position: junction,
            netID: anchor.netID
        )
        let topPad = landingPad(for: viaDef, layer: viaDef.topLayer, at: junction)
        let bottomPad = landingPad(for: viaDef, layer: viaDef.bottomLayer, at: junction)

        let previousLeg = legShapes
        let candidateFixed = frozenLeg + [topPad, bottomPad]
        let update = try drc.apply(LayoutEditDelta(
            addedShapes: candidateFixed,
            removedShapeIDs: previousLeg.map(\.id),
            addedVias: [via]
        ))
        let blocking = newViolations(in: update.result)
        guard blocking.isEmpty else {
            // Roll the switch back exactly: drop the candidate geometry,
            // restore the previous leg.
            _ = try drc.apply(LayoutEditDelta(
                addedShapes: previousLeg,
                removedShapeIDs: candidateFixed.map(\.id),
                removedViaIDs: [via.id]
            ))
            legShapes = previousLeg
            throw InteractiveRouteSessionError.viaPlacementBlocked(blocking)
        }

        fixedShapes.append(contentsOf: candidateFixed)
        fixedVias.append(via)
        legShapes = []
        anchor = RouteAnchor(point: junction, layer: newLayer, netID: anchor.netID)
        refreshSnapTargets()
        lastPreview = preview(
            requestedEnd: junction,
            legalEnd: junction,
            snapReason: .none
        )
        return lastPreview
    }

    // MARK: - Commit / cancel

    /// One delta for the whole route: every leg, via and landing pad as
    /// additions plus the final positions of shoved neighbours as
    /// ID-preserving updates.
    public mutating func commit() -> LayoutEditDelta {
        let delta = commitDelta()
        fixedShapes = []
        fixedVias = []
        legShapes = []
        pushedOriginals = [:]
        pushedCurrent = [:]
        lastPreview = RoutePreview(
            mode: mode,
            requestedEnd: lastPreview.requestedEnd,
            legalEnd: lastPreview.legalEnd,
            snapReason: lastPreview.snapReason,
            stopReason: lastPreview.stopReason,
            delta: delta,
            violations: lastPreview.violations
        )
        return delta
    }

    public mutating func cancel() throws {
        let removedShapeIDs = (fixedShapes + legShapes).map(\.id)
        let restoredNeighbours = pushedOriginals.values
            .sorted { $0.id.isCanonicallyOrderedBefore($1.id) }
        if !removedShapeIDs.isEmpty || !fixedVias.isEmpty || !restoredNeighbours.isEmpty {
            _ = try drc.apply(LayoutEditDelta(
                updatedShapes: restoredNeighbours,
                removedShapeIDs: removedShapeIDs,
                removedViaIDs: fixedVias.map(\.id)
            ))
        }
        fixedShapes = []
        fixedVias = []
        legShapes = []
        pushedOriginals = [:]
        pushedCurrent = [:]
        lastPreview = RoutePreview(
            mode: mode,
            requestedEnd: anchor.point,
            legalEnd: anchor.point,
            snapReason: .none,
            delta: LayoutEditDelta()
        )
    }

    // MARK: - Evaluation

    private mutating func evaluate(
        leg: [LayoutShape]
    ) throws -> (shapes: [LayoutShape], newViolations: [LayoutViolation]) {
        let result = try applyLeg(leg)
        return (leg, newViolations(in: result))
    }

    /// Violations the route gesture must stop for: everything new against
    /// the baseline EXCEPT an open on the route's own net. Being open is
    /// the route's transient nature — closing that open is what the
    /// gesture is doing — while shorts, spacing and width genuinely block.
    /// An own-net open that survives the commit is still reported by the
    /// editor's live sessions afterwards; nothing is hidden permanently.
    private func newViolations(in result: LayoutDRCResult) -> [LayoutViolation] {
        result.violations.filter { violation in
            guard !baselineViolationIDs.contains(ViolationIdentity(of: violation)) else {
                return false
            }
            if violation.kind == .disconnectedOpen,
               let netID = anchor.netID,
               violation.netIDs == [netID] {
                return false
            }
            return true
        }
    }

    private mutating func applyLeg(_ shapes: [LayoutShape]) throws -> LayoutDRCResult {
        let update = try drc.apply(LayoutEditDelta(
            addedShapes: shapes,
            removedShapeIDs: legShapes.map(\.id)
        ))
        legShapes = shapes
        return update.result
    }

    private func commitDelta() -> LayoutEditDelta {
        LayoutEditDelta(
            addedShapes: fixedShapes + legShapes,
            updatedShapes: pushedCurrent.values
                .sorted { $0.id.isCanonicallyOrderedBefore($1.id) },
            addedVias: fixedVias
        )
    }

    private func preview(
        requestedEnd: LayoutPoint,
        legalEnd: LayoutPoint,
        snapReason: RouteSnapReason,
        stopReason: RouteStopReason? = nil,
        violations: [LayoutViolation] = []
    ) -> RoutePreview {
        RoutePreview(
            mode: mode,
            requestedEnd: requestedEnd,
            legalEnd: legalEnd,
            snapReason: snapReason,
            stopReason: stopReason,
            delta: commitDelta(),
            violations: violations,
            pushedShapes: pushedCurrent.values
                .sorted { $0.id.isCanonicallyOrderedBefore($1.id) }
        )
    }

    // MARK: - Shove

    /// Pushes blocking same-layer top-level neighbours perpendicular to
    /// the route until the requested leg is clean, the budget runs out,
    /// or a neighbour would have to move twice (oscillation). Failure
    /// rolls every push back — a route is never half-shoved.
    private mutating func shoveResolve(
        blocking violations: [LayoutViolation]
    ) throws -> Bool {
        let startingOriginals = pushedOriginals
        let startingCurrent = pushedCurrent
        var pushedThisGesture = Set(pushedCurrent.keys)
        var work = violations
        var chain = 0

        while !work.isEmpty {
            guard chain < shoveBudget else {
                try rollbackShove(to: startingOriginals, current: startingCurrent)
                return false
            }
            guard let push = nextPush(in: work, alreadyPushed: pushedThisGesture) else {
                try rollbackShove(to: startingOriginals, current: startingCurrent)
                return false
            }
            if pushedOriginals[push.shape.id] == nil {
                pushedOriginals[push.shape.id] = push.shape
            }
            var moved = push.shape
            moved.geometry = push.shape.geometry.translated(by: push.offset)
            pushedCurrent[moved.id] = moved
            topShapesByID[moved.id] = moved
            pushedThisGesture.insert(moved.id)
            chain += 1

            let result = try drc.apply(LayoutEditDelta(updatedShapes: [moved]))
            work = newViolations(in: result.result)
        }
        return true
    }

    /// The next blocker to push: a top-level, same-layer, foreign-net
    /// shape involved in a violation together with route geometry. The
    /// push direction is perpendicular to the local route segment, away
    /// from it, by the violation's clearance deficit rounded up to grid.
    private func nextPush(
        in violations: [LayoutViolation],
        alreadyPushed: Set<UUID>
    ) -> (shape: LayoutShape, offset: LayoutPoint)? {
        // "Mine" includes already-pushed neighbours so a chain (route
        // pushes B, B now crowds C) keeps resolving outward.
        let myIDs = Set((fixedShapes + legShapes).map(\.id))
            .union(pushedCurrent.keys)
        for violation in violations {
            let blockers = violation.shapeIDs.filter { !myIDs.contains($0) }
            guard blockers.count < violation.shapeIDs.count else { continue }
            for blockerID in blockers {
                guard !alreadyPushed.contains(blockerID),
                      let blocker = topShapesByID[blockerID],
                      blocker.layer == anchor.layer,
                      blocker.netID != anchor.netID else { continue }
                guard let routeShape = nearestRouteShape(to: blocker) else { continue }
                let offset = pushOffset(
                    blocker: blocker,
                    awayFrom: routeShape,
                    deficit: max(violation.required ?? 0, requiredSpacing())
                )
                guard offset.x != 0 || offset.y != 0 else { continue }
                return (blocker, offset)
            }
        }
        return nil
    }

    private func nearestRouteShape(to blocker: LayoutShape) -> LayoutShape? {
        let blockerBox = LayoutGeometryAnalysis.boundingBox(for: blocker.geometry)
        var best: (LayoutShape, Double)? = nil
        for shape in fixedShapes + legShapes {
            let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            let dx = max(box.minX - blockerBox.maxX, blockerBox.minX - box.maxX, 0)
            let dy = max(box.minY - blockerBox.maxY, blockerBox.minY - box.maxY, 0)
            let distance = dx * dx + dy * dy
            if distance < (best?.1 ?? .infinity) {
                best = (shape, distance)
            }
        }
        return best?.0
    }

    private func pushOffset(
        blocker: LayoutShape,
        awayFrom routeShape: LayoutShape,
        deficit: Double
    ) -> LayoutPoint {
        let blockerBox = LayoutGeometryAnalysis.boundingBox(for: blocker.geometry)
        let routeBox = LayoutGeometryAnalysis.boundingBox(for: routeShape.geometry)
        // Choose the axis needing the smaller move to restore clearance.
        let xGap = max(routeBox.minX - blockerBox.maxX, blockerBox.minX - routeBox.maxX)
        let yGap = max(routeBox.minY - blockerBox.maxY, blockerBox.minY - routeBox.maxY)
        let xMove = quantizeUp(deficit - xGap)
        let yMove = quantizeUp(deficit - yGap)
        if xMove <= yMove {
            let direction: Double = blockerBox.center.x >= routeBox.center.x ? 1 : -1
            return LayoutPoint(x: direction * xMove, y: 0)
        }
        let direction: Double = blockerBox.center.y >= routeBox.center.y ? 1 : -1
        return LayoutPoint(x: 0, y: direction * yMove)
    }

    private func quantizeUp(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let grid = tech.grid > 0 ? tech.grid : 1e-3
        return (value / grid).rounded(.up) * grid
    }

    private func requiredSpacing() -> Double {
        tech.ruleSet(for: anchor.layer)?.minSpacing ?? 0
    }

    private mutating func rollbackShove(
        to originals: [UUID: LayoutShape],
        current: [UUID: LayoutShape]
    ) throws {
        // Restore every neighbour pushed beyond the entry state.
        let revert = pushedCurrent.keys
            .filter { current[$0] == nil }
            .sorted { $0.isCanonicallyOrderedBefore($1) }
            .compactMap { pushedOriginals[$0] }
        if !revert.isEmpty {
            _ = try drc.apply(LayoutEditDelta(updatedShapes: revert))
        }
        for shape in revert {
            topShapesByID[shape.id] = shape
        }
        pushedOriginals = originals
        pushedCurrent = current
    }

    // MARK: - Geometry

    private func routeShapes(to end: LayoutPoint) -> [LayoutShape] {
        let corner = LayoutPoint(x: end.x, y: anchor.point.y)
        var shapes: [LayoutShape] = []
        if let horizontal = segmentShape(from: anchor.point, to: corner) {
            shapes.append(horizontal)
        }
        if let vertical = segmentShape(from: corner, to: end) {
            shapes.append(vertical)
        }
        return shapes
    }

    private func polylineShapes(through points: [LayoutPoint]) -> [LayoutShape] {
        var shapes: [LayoutShape] = []
        for index in 1..<points.count {
            let from = points[index - 1]
            let to = points[index]
            if abs(from.x - to.x) > 1e-12 && abs(from.y - to.y) > 1e-12 {
                // Non-orthogonal hop: split through the L corner like a
                // manual tick would.
                let corner = LayoutPoint(x: to.x, y: from.y)
                if let a = segmentShape(from: from, to: corner) { shapes.append(a) }
                if let b = segmentShape(from: corner, to: to) { shapes.append(b) }
            } else if let segment = segmentShape(from: from, to: to) {
                shapes.append(segment)
            }
        }
        return shapes
    }

    private func segmentShape(from: LayoutPoint, to: LayoutPoint) -> LayoutShape? {
        if abs(from.x - to.x) < 1e-12 && abs(from.y - to.y) < 1e-12 {
            return nil
        }
        let width = routeWidth()
        let rect: LayoutRect
        if abs(from.y - to.y) <= abs(from.x - to.x) {
            let minX = min(from.x, to.x)
            let length = abs(from.x - to.x) + width
            rect = LayoutRect(
                origin: LayoutPoint(x: minX - width / 2, y: from.y - width / 2),
                size: LayoutSize(width: length, height: width)
            )
        } else {
            let minY = min(from.y, to.y)
            let length = abs(from.y - to.y) + width
            rect = LayoutRect(
                origin: LayoutPoint(x: from.x - width / 2, y: minY - width / 2),
                size: LayoutSize(width: width, height: length)
            )
        }
        return LayoutShape(
            layer: anchor.layer,
            netID: anchor.netID,
            geometry: .rect(rect)
        )
    }

    private func routeWidth() -> Double {
        requestedWidth ?? tech.ruleSet(for: anchor.layer)?.minWidth ?? 1e-3
    }

    private func landingPad(
        for definition: LayoutViaDefinition,
        layer: LayoutLayerID,
        at point: LayoutPoint
    ) -> LayoutShape {
        // Enclosure is a MINIMUM; a pad sized exactly to it sits on the
        // rule boundary and float rounding can land it fractionally
        // below. One manufacturing-grid step of margin keeps the via
        // robustly legal, the same headroom every router builds in.
        let margin = tech.grid > 0 ? tech.grid : 1e-3
        let enclosure = (layer == definition.topLayer
            ? definition.enclosure.top
            : definition.enclosure.bottom) + margin
        let width = definition.cutSize.width + 2 * enclosure
        let height = definition.cutSize.height + 2 * enclosure
        return LayoutShape(
            layer: layer,
            netID: anchor.netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: point.x - width / 2, y: point.y - height / 2),
                size: LayoutSize(width: width, height: height)
            ))
        )
    }

    // MARK: - Snapping

    private mutating func refreshSnapTargets() {
        snapPins = routeNetPins.filter { $0.layer == anchor.layer }
        snapBoxes = routeNetShapes
            .filter { $0.layer == anchor.layer }
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
    }

    /// Snap priority: same-net pin, then same-net shape edge, then the
    /// manufacturing grid.
    private func snap(_ point: LayoutPoint) -> (point: LayoutPoint, reason: RouteSnapReason) {
        var bestPin: (LayoutPoint, Double)? = nil
        for pin in snapPins {
            let distance = hypot(pin.position.x - point.x, pin.position.y - point.y)
            if distance <= snapRadius, distance < (bestPin?.1 ?? .infinity) {
                bestPin = (pin.position, distance)
            }
        }
        if let bestPin {
            return (bestPin.0, .sameNetPin)
        }

        var bestEdge: (LayoutPoint, Double)? = nil
        for box in snapBoxes {
            let candidate = nearestPerimeterPoint(of: box, to: point)
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance <= snapRadius, distance < (bestEdge?.1 ?? .infinity) {
                bestEdge = (candidate, distance)
            }
        }
        if let bestEdge {
            return (bestEdge.0, .sameNetShapeEdge)
        }

        let grid = tech.grid
        guard grid > 0 else { return (point, .none) }
        return (
            LayoutPoint(
                x: (point.x / grid).rounded() * grid,
                y: (point.y / grid).rounded() * grid
            ),
            .grid
        )
    }

    private func nearestPerimeterPoint(of box: LayoutRect, to point: LayoutPoint) -> LayoutPoint {
        let clampedX = min(max(point.x, box.minX), box.maxX)
        let clampedY = min(max(point.y, box.minY), box.maxY)
        let inside = point.x > box.minX && point.x < box.maxX
            && point.y > box.minY && point.y < box.maxY
        guard inside else {
            return LayoutPoint(x: clampedX, y: clampedY)
        }
        // Inside the box: project to the closest edge.
        let toLeft = point.x - box.minX
        let toRight = box.maxX - point.x
        let toBottom = point.y - box.minY
        let toTop = box.maxY - point.y
        let smallest = min(toLeft, toRight, toBottom, toTop)
        if smallest == toLeft { return LayoutPoint(x: box.minX, y: point.y) }
        if smallest == toRight { return LayoutPoint(x: box.maxX, y: point.y) }
        if smallest == toBottom { return LayoutPoint(x: point.x, y: box.minY) }
        return LayoutPoint(x: point.x, y: box.maxY)
    }
}
