import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

@Suite("InteractiveRouteSession")
struct InteractiveRouteSessionTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    @Test func manualRouteCommitsCleanDelta() throws {
        let netID = UUID()
        let cell = LayoutCell(name: "TOP")
        var document = LayoutDocument(name: "route", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: netID)
        )

        let preview = try session.tick(to: LayoutPoint(x: 2.0, y: 1.0))
        #expect(preview.isLegal)
        #expect(preview.snapReason == RouteSnapReason.grid)

        let delta = session.commit()
        #expect(delta.addedShapes.count == 2)
        apply(delta, to: &document, cellID: cell.id)
        let drc = LayoutDRCService().run(document: document, tech: makeTech())
        #expect(drc.violations.isEmpty)
    }

    @Test func manualRouteStopsBeforeBlockingViolation() throws {
        let routeNet = UUID()
        let blockerNet = UUID()
        let blocker = LayoutShape(
            layer: m1,
            netID: blockerNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.0, y: -0.5),
                size: LayoutSize(width: 0.2, height: 1.0)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [blocker])
        var document = LayoutDocument(name: "route", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: routeNet)
        )

        let preview = try session.tick(to: LayoutPoint(x: 2.0, y: 0))

        #expect(!preview.isLegal)
        #expect(preview.legalEnd.x < 1.0)
        #expect(isOnGrid(preview.legalEnd.x, grid: makeTech().grid))
        #expect(isOnGrid(preview.legalEnd.y, grid: makeTech().grid))
        #expect(!preview.violations.isEmpty)

        let delta = session.commit()
        apply(delta, to: &document, cellID: cell.id)
        let drc = LayoutDRCService().run(document: document, tech: makeTech())
        #expect(drc.violations.isEmpty)
    }

    @Test func cancelDropsPreviewDelta() throws {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "route", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1)
        )

        _ = try session.tick(to: LayoutPoint(x: 2.0, y: 0))
        try session.cancel()
        let delta = session.commit()

        #expect(delta.isEmpty)
    }

    @Test func proposedPathFailureRollsBackToLastLegalPreviewWithDiagnostics() throws {
        let routeNet = UUID()
        let blockerNet = UUID()
        let blocker = LayoutShape(
            layer: m1,
            netID: blockerNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.0, y: -0.5),
                size: LayoutSize(width: 0.2, height: 1.0)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [blocker])
        var document = LayoutDocument(name: "route-proposal-rollback", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: routeNet)
        )

        let legalPreview = try session.tick(to: LayoutPoint(x: 0.5, y: 0))
        #expect(legalPreview.isLegal)
        #expect(legalPreview.delta.addedShapes.count == 1)

        let blockedPreview = try session.proposePath([LayoutPoint(x: 2.0, y: 0)])

        #expect(!blockedPreview.isLegal)
        #expect(blockedPreview.legalEnd == legalPreview.legalEnd)
        #expect(blockedPreview.delta.addedShapes == legalPreview.delta.addedShapes)

        guard case .blockedByViolations(let violations) = blockedPreview.stopReason else {
            Issue.record("Expected blocking diagnostics for an illegal proposed path")
            return
        }
        let short = try #require(violations.first { $0.kind == .overlapShort })
        #expect(short.shapeIDs.contains(blocker.id))
        #expect(Set(short.netIDs) == Set([routeNet, blockerNet]))
        #expect(short.suggestedFix != nil)

        let delta = session.commit()
        #expect(delta.addedShapes == legalPreview.delta.addedShapes)
        #expect(delta.updatedShapes.isEmpty)
        #expect(delta.addedVias.isEmpty)
        apply(delta, to: &document, cellID: cell.id)

        let drc = LayoutDRCService().run(document: document, tech: makeTech())
        #expect(drc.violations.isEmpty, "only the last legal preview may be committed")
    }

    @MainActor
    @Test func editorRouteToolCommitsLegalSegmentThroughTheEditStream() throws {
        // The route starts on a net-carrying pad (the tool inherits the
        // net under the anchor), so crossing the foreign-net blocker is a
        // short and the session must stop before it.
        let routeNet = UUID()
        let blockerNet = UUID()
        let startPad = LayoutShape(
            layer: m1,
            netID: routeNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.2, y: -0.2),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let blocker = LayoutShape(
            layer: m1,
            netID: blockerNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.0, y: -0.5),
                size: LayoutSize(width: 0.2, height: 1.0)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [startPad, blocker])
        let document = LayoutDocument(name: "route", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: makeTech())
        viewModel.activeLayer = m1

        viewModel.beginRoute(at: LayoutPoint(x: 0, y: 0))
        #expect(viewModel.isRouting)

        viewModel.updateRoute(to: LayoutPoint(x: 2.0, y: 0))
        let preview = try #require(viewModel.routePreview)
        #expect(!preview.isLegal)
        #expect(preview.legalEnd.x < 1.0)

        let legalEnd = viewModel.commitRoute()
        #expect(legalEnd != nil)
        #expect(!viewModel.isRouting)
        let shapeCount = viewModel.documentShapes().count
        #expect(shapeCount > 2, "the legal part of the route must be committed")
        #expect(viewModel.violations.isEmpty, "a committed route must be DRC-clean")

        viewModel.undo()
        #expect(viewModel.documentShapes().count == 2, "a route commit is one undo unit")
    }

    @MainActor
    @Test func editorRouteCancelLeavesTheDocumentUntouched() {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "route", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: makeTech())
        viewModel.activeLayer = m1

        viewModel.beginRoute(at: LayoutPoint(x: 0, y: 0))
        viewModel.updateRoute(to: LayoutPoint(x: 2.0, y: 0))
        #expect(viewModel.routePreview != nil)

        viewModel.cancelRoute()
        #expect(!viewModel.isRouting)
        #expect(viewModel.routePreview == nil)
        #expect(viewModel.documentShapes().isEmpty)
        #expect(viewModel.commitRoute() == nil, "commit after cancel must be a no-op")
    }

    // MARK: - Same-net snapping

    @Test func cursorSnapsToSameNetPinThenEdgeThenGrid() throws {
        let netID = UUID()
        let pad = LayoutShape(
            layer: m1,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 3.0, y: 1.0),
                size: LayoutSize(width: 1.0, height: 1.0)
            ))
        )
        let pin = LayoutPin(
            name: "T",
            position: LayoutPoint(x: 5.0, y: 0.2),
            size: LayoutSize(width: 0.2, height: 0.2),
            layer: m1,
            netID: netID
        )
        let cell = LayoutCell(name: "TOP", shapes: [pad], pins: [pin])
        let document = LayoutDocument(name: "snap", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: netID)
        )

        // Within the pin capture radius: the pin wins.
        let pinSnap = try session.tick(to: LayoutPoint(x: 5.1, y: 0.15))
        #expect(pinSnap.snapReason == .sameNetPin)
        #expect(pinSnap.legalEnd == LayoutPoint(x: 5.0, y: 0.2))

        // Near the pad's edge: edge snap.
        let edgeSnap = try session.tick(to: LayoutPoint(x: 3.5, y: 0.9))
        #expect(edgeSnap.snapReason == .sameNetShapeEdge)
        #expect(abs(edgeSnap.legalEnd.y - 1.0) < 1e-9)

        // Far from both: plain grid snap.
        let gridSnap = try session.tick(to: LayoutPoint(x: 1.004, y: -1.498))
        #expect(gridSnap.snapReason == .grid)
    }

    // MARK: - Layer switching

    @Test func switchLayerInsertsViaWithLandingPadsAndCommitIsClean() throws {
        let netID = UUID()
        let cell = LayoutCell(name: "TOP")
        var document = LayoutDocument(name: "via", cells: [cell], topCellID: cell.id)
        let tech = makeTwoLayerTech()
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: tech,
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: netID)
        )

        _ = try session.tick(to: LayoutPoint(x: 2.0, y: 0))
        _ = try session.switchLayer(to: m2)
        #expect(session.currentAnchor.layer == m2)
        let preview = try session.tick(to: LayoutPoint(x: 2.0, y: 2.0))
        #expect(preview.isLegal)

        let delta = session.commit()
        #expect(delta.addedVias.count == 1)
        #expect(
            Set(delta.addedShapes.map(\.layer)).isSuperset(of: [m1, m2]),
            "the route carries geometry on both layers plus landing pads"
        )
        apply(delta, to: &document, cellID: cell.id)
        let drc = LayoutDRCService().run(document: document, tech: tech)
        #expect(drc.violations.isEmpty)
    }

    @Test func switchLayerWithoutAViaDefinitionThrows() throws {
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "via", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),  // single layer, no vias
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: UUID())
        )
        _ = try session.tick(to: LayoutPoint(x: 1.0, y: 0))

        #expect(throws: InteractiveRouteSessionError.noViaBetweenLayers(
            m1, LayoutLayerID(name: "M9", purpose: "drawing")
        )) {
            try session.switchLayer(to: LayoutLayerID(name: "M9", purpose: "drawing"))
        }
    }

    // MARK: - Shove

    @Test func shovePushesABlockingNeighbourAndTheCommitStaysClean() throws {
        let routeNet = UUID()
        let blockerNet = UUID()
        let blocker = LayoutShape(
            layer: m1,
            netID: blockerNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.4, y: -0.5),
                size: LayoutSize(width: 0.2, height: 1.0)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [blocker])
        var document = LayoutDocument(name: "shove", cells: [cell], topCellID: cell.id)
        let tech = makeTech()
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: tech,
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: routeNet),
            mode: .shove
        )

        let preview = try session.tick(to: LayoutPoint(x: 3.0, y: 0))

        #expect(preview.isLegal, "shove must clear the blocker instead of stopping")
        #expect(preview.legalEnd == LayoutPoint(x: 3.0, y: 0))
        #expect(preview.pushedShapes.count == 1)
        let pushed = try #require(preview.pushedShapes.first)
        #expect(pushed.id == blocker.id, "shove must move the neighbour, not replace it")

        let delta = session.commit()
        #expect(delta.updatedShapes.map(\.id) == [blocker.id])
        apply(delta, to: &document, cellID: cell.id)
        let drc = LayoutDRCService().run(document: document, tech: tech)
        #expect(drc.violations.isEmpty, "a committed shove leaves a clean design")
    }

    @Test func shoveBeyondTheBudgetRollsBackAndStopsShort() throws {
        // A picket fence of foreign wires deeper than the shove budget:
        // pushing the first would crowd the second, and so on past the
        // chain limit. The tick must roll every push back and stop short.
        // Every picket on its OWN net: pushing one into the next is a
        // short, so the chain has to keep pushing past the budget.
        var shapes: [LayoutShape] = []
        for index in 0..<12 {
            shapes.append(LayoutShape(
                layer: m1,
                netID: UUID(),
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.4, y: -0.5 + Double(index) * 0.4),
                    size: LayoutSize(width: 0.2, height: 0.2)
                ))
            ))
        }
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "fence", cells: [cell], topCellID: cell.id)
        var session = try InteractiveRouteSession(
            document: document,
            cellID: cell.id,
            tech: makeTech(),
            start: RouteAnchor(point: LayoutPoint(x: 0, y: 0), layer: m1, netID: UUID()),
            mode: .shove,
            shoveBudget: 2
        )

        let preview = try session.tick(to: LayoutPoint(x: 3.0, y: 0))

        #expect(!preview.isLegal)
        // The fence front sits at x = 1.4; half width (0.1) plus spacing
        // (0.2) puts the furthest legal end at 1.1.
        #expect(preview.legalEnd.x < 1.2)
        #expect(preview.pushedShapes.isEmpty, "a failed shove must not leave half-pushed neighbours")

        let delta = session.commit()
        #expect(delta.updatedShapes.isEmpty)
    }

    // MARK: - Auto-complete

    @MainActor
    @Test func autoCompleteRoutesAroundAnObstacleInsideTheWindow() throws {
        let routeNet = UUID()
        let blockerNet = UUID()
        let startPad = LayoutShape(
            layer: m1,
            netID: routeNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.2, y: -0.2),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let blocker = LayoutShape(
            layer: m1,
            netID: blockerNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.5, y: -1.0),
                size: LayoutSize(width: 0.2, height: 2.0)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [startPad, blocker])
        let document = LayoutDocument(name: "auto", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: makeTech())
        viewModel.activeLayer = m1

        viewModel.beginRoute(at: LayoutPoint(x: 0, y: 0))
        viewModel.completeRoute(to: LayoutPoint(x: 3.0, y: 0))

        let preview = try #require(viewModel.routePreview)
        #expect(preview.isLegal, "the search must detour around the blocker inside the window")
        viewModel.commitRoute()
        #expect(viewModel.violations.isEmpty)
        #expect(viewModel.documentShapes().count > 2)
    }

    @MainActor
    @Test func autoCompleteReportsAWindowMissInsteadOfDetouringSilently() {
        // A wall far taller than the auto-complete window: no path exists
        // inside it, and the completion must say so rather than route
        // around the world.
        let wall = LayoutShape(
            layer: m1,
            netID: UUID(),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1.5, y: -50),
                size: LayoutSize(width: 0.2, height: 100)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [wall])
        let document = LayoutDocument(name: "wall", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: makeTech())
        viewModel.activeLayer = m1

        viewModel.beginRoute(at: LayoutPoint(x: 0, y: 0))
        viewModel.completeRoute(to: LayoutPoint(x: 3.0, y: 0))

        #expect(viewModel.lastError != nil)
        #expect(viewModel.routePreview?.isLegal != true)
    }

    private func makeTwoLayerTech() -> LayoutTechDatabase {
        let via1 = LayoutLayerID(name: "VIA1", purpose: "drawing")
        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [m1, m2, via1].map { id in
                LayoutLayerDefinition(
                    id: id,
                    displayName: id.name,
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.2, green: 0.5, blue: 0.9)
                )
            },
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: via1,
                    topLayer: m2,
                    bottomLayer: m1,
                    cutSize: LayoutSize(width: 0.22, height: 0.22),
                    enclosure: LayoutViaEnclosure(top: 0.06, bottom: 0.06),
                    cutSpacing: 0.25
                )
            ],
            layerRules: [
                LayoutLayerRuleSet(layerID: m1, minWidth: 0.2, minSpacing: 0.2, minArea: 0.01, minDensity: 0, maxDensity: 1),
                LayoutLayerRuleSet(layerID: m2, minWidth: 0.2, minSpacing: 0.2, minArea: 0.01, minDensity: 0, maxDensity: 1),
                LayoutLayerRuleSet(layerID: via1, minWidth: 0, minSpacing: 0.25, minArea: 0, minDensity: 0, maxDensity: 1),
            ]
        )
    }

    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    private func makeTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.2, green: 0.5, blue: 0.9)
                )
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.2,
                    minSpacing: 0.2,
                    minArea: 0.01,
                    minDensity: 0,
                    maxDensity: 1
                )
            ]
        )
    }

    private func apply(_ delta: LayoutEditDelta, to document: inout LayoutDocument, cellID: UUID) {
        var cell = document.cell(withID: cellID)!
        cell.shapes.removeAll { delta.removedShapeIDs.contains($0.id) }
        for shape in delta.updatedShapes {
            if let index = cell.shapes.firstIndex(where: { $0.id == shape.id }) {
                cell.shapes[index] = shape
            }
        }
        cell.shapes.append(contentsOf: delta.addedShapes)
        cell.vias.removeAll { delta.removedViaIDs.contains($0.id) }
        for via in delta.updatedVias {
            if let index = cell.vias.firstIndex(where: { $0.id == via.id }) {
                cell.vias[index] = via
            }
        }
        cell.vias.append(contentsOf: delta.addedVias)
        document.updateCell(cell)
    }

    private func isOnGrid(_ value: Double, grid: Double) -> Bool {
        guard grid > 0 else { return true }
        let snapped = (value / grid).rounded() * grid
        return abs(value - snapped) < 1e-9
    }
}
