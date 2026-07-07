import Foundation
import LayoutCore
import LayoutVerify

extension LayoutEditorViewModel {
    // MARK: - finish-net (N3)

    /// Completes one open of `netID` with the auto-route machinery,
    /// gated: the net's open count must shrink and DRC must not regress,
    /// else the commit is rolled back bit-exact. Surfaced errors carry
    /// the blocking reason; the document is never left half-routed.
    @discardableResult
    public func finishNet(_ netID: UUID) -> Bool {
        guard !isEditingInPlace else {
            handleError(LayoutEditorError.routingUnavailableInPlace)
            return false
        }
        guard let analysis = connectivityAnalysis,
              let open = analysis.opens.first(where: { $0.netID == netID }),
              let flyline = open.flylines.first else {
            handleError(LayoutEditorError.netAlreadyConnected(netID))
            return false
        }
        // The target is the ISLAND, not the flyline's corner point: the
        // nearest-point can sit inside foreign clearance while the rest
        // of the island is perfectly reachable. Footprints are occurrence
        // exact; resolving shapeIDs would alias reused child shapes onto
        // OTHER instances' geometry.
        var targetRegion: [LayoutRect] = []
        if open.islands.indices.contains(flyline.toIslandIndex) {
            targetRegion = open.islands[flyline.toIslandIndex].memberFootprints
                .filter { $0.layer == activeLayer }
                .map(\.boundingBox)
        }
        let flylinesBefore = analysis.flylines.count { $0.netID == netID }
        // DRC regression is judged by violation IDENTITY, not count: a
        // route that fixes two opens while creating one short would pass
        // a count check. The net's own residual open is exempt — its
        // member set changes with every leg, which would otherwise read
        // as a new violation on a multi-island net.
        let identitiesBefore = Set(violations.map(ViolationIdentity.init))

        // The goal-level route uses this layer's minimum legal width —
        // exactly, not the interactive default, which belongs to another
        // layer and can be thinner (illegal) or much fatter (its
        // clearance envelope walls off every landing).
        let savedPathWidth = pathWidth
        if let minWidth = tech.ruleSet(for: activeLayer)?.minWidth, minWidth > 0 {
            pathWidth = minWidth
        }
        defer { pathWidth = savedPathWidth }
        // Goal legs merge into own metal at both ends; an extended cap
        // would stick half a width past the pin and shave the clearance
        // to the terminal fence below it.
        let savedPathEndCap = pathEndCap
        pathEndCap = .truncate
        defer { pathEndCap = savedPathEndCap }

        // Bounded escalation ladder: analog pin rows often leave no
        // planar corridor inside the tight flyline window, while a
        // detour around the row exists just outside it. Each retry
        // widens the window explicitly (the completer itself never
        // widens) and coarsens the lattice so the search stays bounded;
        // `proposePath` re-judges the found path against exact DRC, so
        // a coarser lattice can only miss paths, never legalize bad
        // ones. A miss after the widest window is the surfaced reason.
        let flylineSpanX = abs(flyline.start.x - flyline.end.x)
        let flylineSpanY = abs(flyline.start.y - flyline.end.y)
        var lastReason = "no clear path inside the search window"
        var routed = false
        for margin in [2.0, 8.0, 32.0, 128.0] {
            cancelRoute()
            beginRoute(at: flyline.start, netID: netID)
            guard isRouting else { return false }
            let windowWidth = flylineSpanX + 2 * margin
            let windowHeight = flylineSpanY + 2 * margin
            // The lattice pitch must stay an integer multiple of the
            // edit grid: pins and cell geometry are grid-aligned, and a
            // misaligned corner lands a wire edge at a sub-spacing gap
            // that exact DRC then rejects.
            let rawStep = (windowWidth * windowHeight / 1_500_000).squareRoot()
            let boundedStep = max(gridSize, (rawStep / gridSize).rounded(.up) * gridSize)
            completeRoute(
                to: flyline.end,
                windowMargin: margin,
                targetRegion: targetRegion,
                step: boundedStep
            )
            if let preview = routePreview, preview.isLegal {
                routed = true
                break
            }
            if case .blockedByViolations(let blocking)? = routePreview?.stopReason,
               let first = blocking.first {
                lastReason = first.message
            }
        }
        // Over-route: when no planar window holds a path — analog
        // terminal fences below the row wall nets off from each other —
        // jump to the paired wiring layer, cross there, and drop back
        // onto the target island. A via cannot land INSIDE a pin pocket
        // (its landing pads violate against the neighboring terminals),
        // so both jump points are chosen from nearby via-legal spots and
        // reached by short planar legs. Every leg and both vias go
        // through the same exact-DRC judge as a planar route.
        if !routed, let jumpLayer = overRouteLayer(above: activeLayer) {
            let savedActiveLayer = activeLayer
            // Candidate via spots near both endpoints. Some sit in sealed
            // micro-pockets between terminal fences, so the escape leg
            // hands ALL of them to the window search as landing regions
            // and lets reachability pick the workable one.
            let upSpots = clearViaSpots(near: flyline.start, on: activeLayer, excluding: netID)
            let downSpots = clearViaSpots(near: flyline.end, on: activeLayer, excluding: netID)
            let upSpotRegion = upSpots.map { spot in
                LayoutRect(
                    origin: LayoutPoint(x: spot.x - 0.05, y: spot.y - 0.05),
                    size: LayoutSize(width: 0.1, height: 0.1)
                )
            }
            overRoute: for downSpot in downSpots {
                cancelRoute()
                activeLayer = savedActiveLayer
                beginRoute(at: flyline.start, netID: netID)
                guard isRouting, let firstSpot = upSpots.first else { break overRoute }

                let escapeMargin = 8.0
                let escapeSpanX = abs(flyline.start.x - firstSpot.x) + 2 * escapeMargin
                let escapeSpanY = abs(flyline.start.y - firstSpot.y) + 2 * escapeMargin
                let escapeRawStep = (escapeSpanX * escapeSpanY / 1_500_000).squareRoot()
                let escapeStep = max(gridSize, (escapeRawStep / gridSize).rounded(.up) * gridSize)
                completeRoute(
                    to: firstSpot,
                    windowMargin: escapeMargin,
                    targetRegion: upSpotRegion,
                    step: escapeStep,
                    allowBlockedRegionGoal: false
                )
                guard let escapeLeg = routePreview, escapeLeg.isLegal else { break overRoute }

                activeLayer = jumpLayer
                guard routeSession?.currentAnchor.layer == jumpLayer else { continue }

                let anchor = routeSession?.currentAnchor.point ?? firstSpot
                let crossingSpanX = abs(anchor.x - downSpot.x)
                let crossingSpanY = abs(anchor.y - downSpot.y)
                var crossed = false
                for margin in [2.0, 8.0, 32.0] {
                    let rawStep = ((crossingSpanX + 2 * margin) * (crossingSpanY + 2 * margin) / 1_500_000)
                        .squareRoot()
                    let boundedStep = max(gridSize, (rawStep / gridSize).rounded(.up) * gridSize)
                    completeRoute(to: downSpot, windowMargin: margin, step: boundedStep)
                    if let crossing = routePreview, crossing.isLegal {
                        crossed = true
                        break
                    }
                }
                guard crossed else { continue }

                activeLayer = savedActiveLayer
                guard routeSession?.currentAnchor.layer == savedActiveLayer else { continue }

                completeRoute(to: flyline.end, targetRegion: targetRegion)
                if let landing = routePreview, landing.isLegal {
                    routed = true
                    break overRoute
                }
            }
            activeLayer = savedActiveLayer
        }
        guard routed else {
            cancelRoute()
            handleError(LayoutEditorError.finishNetBlocked(lastReason))
            return false
        }
        commitRoute()

        let flylinesAfter = connectivityAnalysis?.flylines.count { $0.netID == netID } ?? 0
        let regressed = violations.contains { violation in
            guard !identitiesBefore.contains(ViolationIdentity(of: violation)) else { return false }
            return !(violation.kind == .disconnectedOpen && violation.netIDs == [netID])
        }
        if flylinesAfter >= flylinesBefore || regressed {
            undo()
            handleError(LayoutEditorError.finishNetRegressed)
            return false
        }
        return true
    }

    /// The paired wiring layer reachable from `layer` through a via
    /// definition, for over-routing across planar blockages.
    private func overRouteLayer(above layer: LayoutLayerID) -> LayoutLayerID? {
        if let via = tech.vias.first(where: { $0.bottomLayer == layer }) {
            return via.topLayer
        }
        if let via = tech.vias.first(where: { $0.topLayer == layer }) {
            return via.bottomLayer
        }
        return nil
    }

    /// Nearby points where a via and its landing pads clear the foreign
    /// geometry on `layer` — pin pockets themselves never qualify, their
    /// neighbors are closer than a landing pad allows. Scans grid rings
    /// outward from `point` and returns the nearest few candidates; the
    /// via placement is still DRC-judged when the route actually drops
    /// it there.
    private func clearViaSpots(
        near point: LayoutPoint,
        on layer: LayoutLayerID,
        excluding netID: UUID,
        limit: Int = 24
    ) -> [LayoutPoint] {
        let width = tech.ruleSet(for: layer)?.minWidth ?? 0.1
        let spacing = tech.ruleSet(for: layer)?.minSpacing ?? 0
        // Landing pads outsize the wire; demand a full wire-width of
        // extra clearance so the pad and its enclosure fit.
        let clearance = width + spacing
        let radius = max(4.0, clearance * 16)
        let window = LayoutRect(
            origin: LayoutPoint(x: point.x - radius, y: point.y - radius),
            size: LayoutSize(width: 2 * radius, height: 2 * radius)
        )
        let inflated = (connectivityAnalysis?.nets ?? [])
            .filter { !$0.declaredNetIDs.contains(netID) }
            .flatMap(\.memberFootprints)
            .filter { $0.layer == layer }
            .map(\.boundingBox)
            .filter { $0.intersects(window) }
            .map { $0.expanded(by: clearance, clearance) }
        let step = max(gridSize, 0.01)
        let cells = Int((radius / step).rounded(.up))
        // Diversify: candidates keep a minimum separation so they sample
        // DIFFERENT clear pockets, not one pocket many times — some
        // pockets are sealed for planar travel and reachability decides.
        let separation = max(0.4, clearance)
        var spots: [LayoutPoint] = []
        for ring in 0...max(cells, 1) {
            for dc in -ring...ring {
                for dr in -ring...ring where abs(dc) == ring || abs(dr) == ring {
                    let candidate = LayoutPoint(
                        x: point.x + Double(dc) * step,
                        y: point.y + Double(dr) * step
                    )
                    guard !inflated.contains(where: { $0.contains(candidate) }) else { continue }
                    guard spots.allSatisfy({ spot in
                        let dx = spot.x - candidate.x
                        let dy = spot.y - candidate.y
                        return (dx * dx + dy * dy).squareRoot() >= separation
                    }) else { continue }
                    spots.append(candidate)
                    if spots.count >= limit {
                        return spots
                    }
                }
            }
        }
        return spots
    }

    /// Finishes every finishable open net to a fixed point. Nets that
    /// fail keep their surfaced reason and are skipped; the return value
    /// is the number of completed connections.
    @discardableResult
    public func finishAllNets(budget: Int = 64) -> Int {
        var completed = 0
        var failed: Set<UUID> = []
        for _ in 0..<budget {
            // Longest flyline first: long nets need the clean corridors,
            // and short local hops still succeed after them — the
            // opposite order lets short nets fence off the long ones.
            let candidates = (connectivityAnalysis?.flylines ?? [])
                .filter { !failed.contains($0.netID) }
            guard let flyline = candidates.max(by: { lhs, rhs in
                let lhsSpan = abs(lhs.start.x - lhs.end.x) + abs(lhs.start.y - lhs.end.y)
                let rhsSpan = abs(rhs.start.x - rhs.end.x) + abs(rhs.start.y - rhs.end.y)
                return lhsSpan < rhsSpan
            }) else { break }
            if finishNet(flyline.netID) {
                completed += 1
            } else {
                failed.insert(flyline.netID)
            }
        }
        return completed
    }

    // MARK: - Repairs (N1)

    /// Computes a verified repair (or the typed reason none exists) for
    /// one current violation. Runs batch DRC mirrors internally — a
    /// user-initiated query, not a per-frame call.
    public func repairOutcome(for violation: LayoutViolation) -> LayoutRepairOutcome? {
        guard let cellID = editTargetCellID else { return nil }
        do {
            return try LayoutRepairEngine(
                document: editor.document,
                tech: tech,
                cellID: cellID
            ).repair(for: violation)
        } catch {
            handleError(error)
            return nil
        }
    }

    /// Applies a computed repair through the single edit stream (one undo
    /// unit; every live session follows).
    public func applyRepair(_ repair: LayoutRepair) {
        commitDelta(repair.delta)
    }

    /// Repairs every repairable violation to a fixed point and reports
    /// what was applied and what remains (with reasons). Each repair is
    /// one undo step, in application order.
    @discardableResult
    public func fixAllViolations(budget: Int = 64) -> LayoutRepairSweep? {
        guard let cellID = editTargetCellID else { return nil }
        do {
            let engine = LayoutRepairEngine(
                document: editor.document,
                tech: tech,
                cellID: cellID
            )
            let (repairs, sweep) = try engine.sweep(budget: budget)
            for repair in repairs {
                commitDelta(repair.delta)
            }
            return sweep
        } catch {
            handleError(error)
            return nil
        }
    }

    // MARK: - Focus / Navigation (N1 surfacing)

    /// Frames a micron-space rect in the canvas with padding.
    public func zoom(to rect: LayoutRect, padding: Double = 1.0) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let width = rect.size.width + 2 * padding
        let height = rect.size.height + 2 * padding
        guard width > 0, height > 0 else { return }
        let scale = min(
            Double(canvasSize.width) / width,
            Double(canvasSize.height) / height
        )
        zoom = CGFloat(min(max(scale, 0.01), 10_000))
        offset = CGPoint(
            x: -CGFloat(rect.minX - padding) * zoom
                + (canvasSize.width - CGFloat(width) * zoom) / 2,
            y: -CGFloat(rect.minY - padding) * zoom
                + (canvasSize.height - CGFloat(height) * zoom) / 2
        )
    }

    /// Cycles canvas focus through the current violations (forward or
    /// backward), zooming to each — the triage loop.
    public func focusNextViolation(forward: Bool = true) {
        let all = violations
        guard !all.isEmpty else {
            focusedViolationID = nil
            return
        }
        let currentIndex = focusedViolationID.flatMap { id in
            all.firstIndex(where: { $0.id == id })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + (forward ? 1 : all.count - 1)) % all.count
        } else {
            nextIndex = forward ? 0 : all.count - 1
        }
        let target = all[nextIndex]
        focusedViolationID = target.id
        zoom(to: target.region)
    }

    public func focusViolation(_ violation: LayoutViolation) {
        focusedViolationID = violation.id
        zoom(to: violation.region)
    }

}
