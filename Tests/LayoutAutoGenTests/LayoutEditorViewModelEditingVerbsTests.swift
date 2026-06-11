import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutEditor

/// Contract of the M4 editing verbs (marquee selection, duplicate,
/// rotate, mirror, handle stretch/vertex editing, Option-drag copy):
/// every verb flows through the single commitDelta stream, so after each
/// one — including mid-gesture transient states — the published
/// violations must equal a from-scratch batch DRC run and the published
/// connectivity must equal a from-scratch batch extraction. Gestures
/// collapse into one undo step; cancel restores the origin exactly.
@MainActor
@Suite("LayoutEditorViewModel editing verbs", .timeLimit(.minutes(5)))
struct LayoutEditorViewModelEditingVerbsTests {

    private struct Fixture {
        var viewModel: LayoutEditorViewModel
        var rich: IncrementalDRCEquivalenceHarness.RichFixture
        /// Shape IDs present in the active cell before any edit.
        var initialShapeIDs: Set<UUID>
        /// M1 wire on net B (not exposed by the rich fixture directly).
        var wireB: LayoutShape
        /// M2 pad on net A.
        var padA: LayoutShape
        /// Unlabeled cover on the mark layer spanning (-0.5,-0.5)–(5.5,5.5).
        var markCover: LayoutShape
    }

    private static func makeFixture() throws -> Fixture {
        let rich = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let viewModel = LayoutEditorViewModel(document: rich.document, tech: rich.tech)
        let shapes = viewModel.documentShapes()
        return Fixture(
            viewModel: viewModel,
            rich: rich,
            initialShapeIDs: Set(shapes.map(\.id)),
            wireB: try #require(shapes.first { $0.layer == rich.m1 && $0.netID == rich.netB }),
            padA: try #require(shapes.first { $0.layer == rich.m2 && $0.netID == rich.netA }),
            markCover: try #require(shapes.first { $0.layer == rich.mark })
        )
    }

    // MARK: - Oracles

    /// Discrete-edit oracle: the deferred tier is committed, so the live
    /// violations must equal a batch run exactly, antenna included.
    private func expectDRCMatchesBatchExactly(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            viewModel.staleViolationKinds.isEmpty,
            "\(context): a discrete edit must commit the deferred tier",
            sourceLocation: sourceLocation
        )
        let reference = LayoutDRCService().run(
            document: viewModel.editor.document,
            tech: viewModel.tech,
            cellID: viewModel.activeCellID
        )
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(
                viewModel.violations, excludingAntenna: false
            ) == IncrementalDRCEquivalenceHarness.canonicalCounts(
                reference.violations, excludingAntenna: false
            ),
            "\(context): live violations must equal a from-scratch batch run",
            sourceLocation: sourceLocation
        )
    }

    /// Mid-gesture oracle: the antenna tier is declared stale, everything
    /// else must already equal the batch run.
    private func expectDRCMatchesBatchExceptAntenna(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            viewModel.staleViolationKinds == [.antenna],
            "\(context): a transient edit must declare the deferred antenna tier stale",
            sourceLocation: sourceLocation
        )
        let reference = LayoutDRCService().run(
            document: viewModel.editor.document,
            tech: viewModel.tech,
            cellID: viewModel.activeCellID
        )
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(
                viewModel.violations, excludingAntenna: true
            ) == IncrementalDRCEquivalenceHarness.canonicalCounts(
                reference.violations, excludingAntenna: true
            ),
            "\(context): live violations (minus the stale tier) must equal a batch run",
            sourceLocation: sourceLocation
        )
    }

    private func expectConnectivityMatchesBatch(
        _ viewModel: LayoutEditorViewModel,
        _ context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let reference = try LayoutConnectivityExtractor().extract(
            document: viewModel.editor.document,
            tech: viewModel.tech,
            cellID: viewModel.activeCellID
        )
        let live = try #require(
            viewModel.connectivityAnalysis,
            "\(context): live connectivity must be available",
            sourceLocation: sourceLocation
        )
        #expect(
            live == reference,
            "\(context): live analysis must equal a from-scratch batch extraction",
            sourceLocation: sourceLocation
        )
    }

    private func opens(_ viewModel: LayoutEditorViewModel, net: UUID) -> Bool {
        viewModel.connectivityAnalysis?.opens.contains { $0.netID == net } ?? false
    }

    private func geometry(
        of id: UUID, in viewModel: LayoutEditorViewModel
    ) throws -> LayoutGeometry {
        try #require(
            viewModel.documentShapes().first { $0.id == id }?.geometry,
            "shape \(id) must exist"
        )
    }

    // MARK: - Marquee selection

    @Test func marqueeWindowAndCrossingSemantics() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        // Box around the bottom row: wire A and pad A are fully inside;
        // the mark cover and net-B row are not, but the cover intersects.
        let bottomRow = LayoutRect(
            origin: LayoutPoint(x: -0.6, y: -0.1),
            size: LayoutSize(width: 8.7, height: 0.6)
        )
        viewModel.selectShapes(in: bottomRow, mode: .window)
        #expect(
            viewModel.selectedShapeIDs == [fixture.rich.wireA.id, fixture.padA.id],
            "window selects only shapes whose bounds lie entirely inside the box"
        )

        viewModel.selectShapes(in: bottomRow, mode: .crossing)
        #expect(
            viewModel.selectedShapeIDs
                == [fixture.rich.wireA.id, fixture.padA.id, fixture.markCover.id],
            "crossing also selects shapes that merely intersect the box"
        )

        // A box overlapping only the middle of wire A: window selects
        // nothing, crossing grabs the wire (plus the cover it crosses).
        let sliver = LayoutRect(
            origin: LayoutPoint(x: 6.0, y: -0.1),
            size: LayoutSize(width: 1.0, height: 0.6)
        )
        viewModel.selectShapes(in: sliver, mode: .window)
        #expect(viewModel.selectedShapeIDs.isEmpty)
        viewModel.selectShapes(in: sliver, mode: .crossing)
        #expect(viewModel.selectedShapeIDs == [fixture.rich.wireA.id])

        // Additive marquee unions with the existing selection.
        viewModel.selectShapes(in: bottomRow, mode: .window)
        viewModel.selectShapes(
            in: LayoutRect(
                origin: LayoutPoint(x: 7.2, y: 1.4),
                size: LayoutSize(width: 1.0, height: 0.6)
            ),
            mode: .crossing,
            additive: true
        )
        #expect(
            viewModel.selectedShapeIDs
                == [fixture.rich.wireA.id, fixture.padA.id, fixture.wireB.id]
        )

        // Hidden layers never participate.
        viewModel.hiddenLayers.insert(fixture.rich.mark)
        viewModel.selectShapes(in: bottomRow, mode: .crossing)
        #expect(
            viewModel.selectedShapeIDs == [fixture.rich.wireA.id, fixture.padA.id],
            "shapes on hidden layers must not be marquee-selectable"
        )
        viewModel.hiddenLayers.remove(fixture.rich.mark)

        // A non-additive marquee over empty space clears the selection,
        // and a hit clears any instance selection.
        viewModel.selectShapes(
            in: LayoutRect(
                origin: LayoutPoint(x: 50, y: 50),
                size: LayoutSize(width: 1, height: 1)
            ),
            mode: .crossing
        )
        #expect(viewModel.selectedShapeIDs.isEmpty)

        viewModel.selectedInstanceID = UUID()
        viewModel.selectShapes(in: bottomRow, mode: .window)
        #expect(viewModel.selectedInstanceID == nil)
    }

    // MARK: - Duplicate

    @Test func duplicateKeepsNetAndReportsHonestOpen() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        #expect(!opens(viewModel, net: fixture.rich.netA))

        viewModel.selectedShapeIDs = [fixture.rich.wireA.id]
        viewModel.duplicateSelectedShapes(by: LayoutPoint(x: 0, y: 3.0))

        let copy = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) },
            "duplicate must add exactly one fresh shape"
        )
        #expect(copy.id != fixture.rich.wireA.id)
        #expect(copy.layer == fixture.rich.m1)
        #expect(copy.netID == fixture.rich.netA, "the copy keeps its net assignment")
        #expect(copy.geometry == fixture.rich.wireA.geometry.translated(
            by: LayoutPoint(x: 0, y: 3.0)
        ))
        #expect(viewModel.selectedShapeIDs == [copy.id], "selection moves to the copy")
        #expect(
            viewModel.documentShapes().contains { $0.id == fixture.rich.wireA.id },
            "the original stays put"
        )

        // The copied labeled wire is disconnected from net A's via stack:
        // that open must be reported, not hidden.
        #expect(opens(viewModel, net: fixture.rich.netA))
        expectDRCMatchesBatchExactly(viewModel, "after duplicate")
        try expectConnectivityMatchesBatch(viewModel, "after duplicate")

        // One discrete edit, one undo step.
        viewModel.undo()
        #expect(Set(viewModel.documentShapes().map(\.id)) == fixture.initialShapeIDs)
        #expect(!opens(viewModel, net: fixture.rich.netA))
        try expectConnectivityMatchesBatch(viewModel, "after undo")
    }

    // MARK: - Rotate

    @Test func rotateQuarterTurnIsIDPreservingAndVerified() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let wireID = fixture.rich.wireA.id
        let original = fixture.rich.wireA.geometry

        // Pivot rule: the grid-snapped center of the selection's combined
        // bounding box — for wire A alone, (4, 0.2).
        let pivot = viewModel.snapToGrid(
            LayoutGeometryAnalysis.boundingBox(for: original).center
        )
        viewModel.selectedShapeIDs = [wireID]
        viewModel.rotateSelectedShapes(clockwise: true)

        let turned = try geometry(of: wireID, in: viewModel)
        #expect(
            turned == original.rotated90(around: pivot, clockwise: true),
            "rotation pivots on the grid-snapped selection-bbox center, ID preserved"
        )
        guard case .rect(let turnedRect) = turned else {
            Issue.record("a rotated rect must stay a rect")
            return
        }
        // The pivot's 0.2 offset is not float-representable, so the swapped
        // dimensions carry ~1e-16 rounding noise; the exact contract is the
        // API equality above.
        #expect(
            abs(turnedRect.size.width - 0.4) <= 1e-12
                && abs(turnedRect.size.height - 8.0) <= 1e-12
        )

        // The vertical wire no longer covers via A: the open and the
        // batch equivalence prove verification tracked the verb.
        #expect(opens(viewModel, net: fixture.rich.netA))
        expectDRCMatchesBatchExactly(viewModel, "after rotate CW")
        try expectConnectivityMatchesBatch(viewModel, "after rotate CW")

        // CCW about the re-derived pivot restores the wire. The float round
        // trip carries ~1e-16 noise (the 0.2 pivot offset is not exactly
        // representable), so the restore is pinned bit-exactly against the
        // geometry API and within tolerance against the original.
        let ccwPivot = viewModel.snapToGrid(
            LayoutGeometryAnalysis.boundingBox(for: turned).center
        )
        viewModel.rotateSelectedShapes(clockwise: false)
        let restored = try geometry(of: wireID, in: viewModel)
        #expect(restored == turned.rotated90(around: ccwPivot, clockwise: false))
        guard case .rect(let restoredRect) = restored,
              case .rect(let originalRect) = original else {
            Issue.record("the restored wire must stay a rect")
            return
        }
        #expect(abs(restoredRect.origin.x - originalRect.origin.x) <= 1e-12)
        #expect(abs(restoredRect.origin.y - originalRect.origin.y) <= 1e-12)
        #expect(abs(restoredRect.size.width - originalRect.size.width) <= 1e-12)
        #expect(abs(restoredRect.size.height - originalRect.size.height) <= 1e-12)
        #expect(!opens(viewModel, net: fixture.rich.netA))
        expectDRCMatchesBatchExactly(viewModel, "after rotate CCW")
        try expectConnectivityMatchesBatch(viewModel, "after rotate CCW")
    }

    // MARK: - Mirror

    @Test func mirrorAcrossSelectionCenterIsVerified() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let padID = fixture.rich.padB.id
        let padGeometry = fixture.rich.padB.geometry
        let wireGeometry = fixture.rich.wireA.geometry
        #expect(!opens(viewModel, net: fixture.rich.netB))

        // Selection {wire A, pad B}: bbox (0,0)–(8,1.9), center (4, 0.95).
        viewModel.selectedShapeIDs = [fixture.rich.wireA.id, padID]
        let pivot = viewModel.snapToGrid(
            LayoutGeometryAnalysis.boundingBox(for: wireGeometry)
                .union(LayoutGeometryAnalysis.boundingBox(for: padGeometry))
                .center
        )
        viewModel.mirrorSelectedShapes(across: .vertical)

        #expect(
            try geometry(of: fixture.rich.wireA.id, in: viewModel)
                == wireGeometry.mirrored(across: .vertical, through: pivot),
            "the full-width wire maps onto itself"
        )
        #expect(
            try geometry(of: padID, in: viewModel)
                == padGeometry.mirrored(across: .vertical, through: pivot),
            "pad B reflects to the other side of the selection center"
        )

        // The mirrored pad left its via: net B must report open, and both
        // oracles must agree with batch.
        #expect(opens(viewModel, net: fixture.rich.netB))
        expectDRCMatchesBatchExactly(viewModel, "after mirror")
        try expectConnectivityMatchesBatch(viewModel, "after mirror")

        // Mirroring again restores the arrangement and heals the net. The
        // 0.95 pivot offset is not float-representable, so the restore is
        // pinned bit-exactly against the geometry API (with the pivot
        // re-derived from the mirrored selection, as the verb does) and
        // within tolerance against the original.
        let mirroredWire = try geometry(of: fixture.rich.wireA.id, in: viewModel)
        let mirroredPad = try geometry(of: padID, in: viewModel)
        let secondPivot = viewModel.snapToGrid(
            LayoutGeometryAnalysis.boundingBox(for: mirroredWire)
                .union(LayoutGeometryAnalysis.boundingBox(for: mirroredPad))
                .center
        )
        viewModel.mirrorSelectedShapes(across: .vertical)
        let restoredPad = try geometry(of: padID, in: viewModel)
        #expect(
            restoredPad
                == mirroredPad.mirrored(across: .vertical, through: secondPivot)
        )
        guard case .rect(let restoredRect) = restoredPad,
              case .rect(let originalRect) = padGeometry else {
            Issue.record("the restored pad must stay a rect")
            return
        }
        #expect(abs(restoredRect.origin.x - originalRect.origin.x) <= 1e-12)
        #expect(abs(restoredRect.origin.y - originalRect.origin.y) <= 1e-12)
        #expect(abs(restoredRect.size.width - originalRect.size.width) <= 1e-12)
        #expect(abs(restoredRect.size.height - originalRect.size.height) <= 1e-12)
        #expect(!opens(viewModel, net: fixture.rich.netB))
        expectDRCMatchesBatchExactly(viewModel, "after mirror back")
        try expectConnectivityMatchesBatch(viewModel, "after mirror back")
    }

    // MARK: - Handle drag (stretch)

    @Test func handleDragStretchesLiveAndUndoesAsOneStep() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let wireID = fixture.rich.wireA.id
        let original = fixture.rich.wireA.geometry

        viewModel.selectedShapeIDs = [wireID]
        #expect(viewModel.beginHandleDrag(shapeID: wireID, handle: .edge(1)))
        #expect(viewModel.isDraggingHandle)

        // Every tick re-verifies: stretch right by 1um, then to a second
        // position — each recomputed from the origin geometry.
        viewModel.updateHandleDrag(to: LayoutPoint(x: 1.0, y: 0))
        #expect(try geometry(of: wireID, in: viewModel) == .rect(LayoutRect(
            origin: .zero, size: LayoutSize(width: 9, height: 0.4)
        )))
        expectDRCMatchesBatchExceptAntenna(viewModel, "mid-drag +1.0")
        try expectConnectivityMatchesBatch(viewModel, "mid-drag +1.0")

        viewModel.updateHandleDrag(to: LayoutPoint(x: -2.0, y: 0))
        #expect(try geometry(of: wireID, in: viewModel) == .rect(LayoutRect(
            origin: .zero, size: LayoutSize(width: 6, height: 0.4)
        )), "offsets are cumulative from the origin, not from the last tick")
        expectDRCMatchesBatchExceptAntenna(viewModel, "mid-drag -2.0")
        try expectConnectivityMatchesBatch(viewModel, "mid-drag -2.0")

        viewModel.endHandleDrag()
        #expect(!viewModel.isDraggingHandle)
        expectDRCMatchesBatchExactly(viewModel, "after end")
        try expectConnectivityMatchesBatch(viewModel, "after end")

        // The whole gesture is one undo step.
        viewModel.undo()
        #expect(try geometry(of: wireID, in: viewModel) == original)
        expectDRCMatchesBatchExactly(viewModel, "after undo")
        try expectConnectivityMatchesBatch(viewModel, "after undo")
    }

    @Test func handleDragSurfacesViolationsAndCancelRestoresExactly() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let wireID = fixture.rich.wireA.id
        let original = fixture.rich.wireA.geometry
        let preDragCounts = IncrementalDRCEquivalenceHarness.canonicalCounts(
            viewModel.violations, excludingAntenna: false
        )
        let spacingBetweenWires: (LayoutEditorViewModel) -> Bool = { vm in
            vm.violations.contains {
                $0.kind == .minSpacing
                    && Set($0.shapeIDs).isSuperset(of: [wireID, fixture.wireB.id])
            }
        }
        #expect(!spacingBetweenWires(viewModel))

        // Stretching wire A's top edge to within 0.2um of wire B (min
        // spacing 0.23) must surface the violation while the pointer is
        // still down.
        viewModel.selectedShapeIDs = [wireID]
        #expect(viewModel.beginHandleDrag(shapeID: wireID, handle: .edge(2)))
        viewModel.updateHandleDrag(to: LayoutPoint(x: 0, y: 0.9))
        #expect(
            spacingBetweenWires(viewModel),
            "the spacing violation must appear mid-gesture"
        )
        expectDRCMatchesBatchExceptAntenna(viewModel, "mid-drag spacing")
        try expectConnectivityMatchesBatch(viewModel, "mid-drag spacing")

        // Cancel restores the origin geometry and the origin verdict.
        viewModel.cancelHandleDrag()
        #expect(!viewModel.isDraggingHandle)
        #expect(try geometry(of: wireID, in: viewModel) == original)
        #expect(!spacingBetweenWires(viewModel))
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(
                viewModel.violations, excludingAntenna: false
            ) == preDragCounts,
            "cancel must restore the pre-gesture violation set exactly"
        )
        try expectConnectivityMatchesBatch(viewModel, "after cancel")
    }

    @Test func polygonVertexHandleAndInvalidHandles() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.activeLayer = fixture.rich.m1
        viewModel.addPolygon(points: [
            LayoutPoint(x: 10, y: 0),
            LayoutPoint(x: 11, y: 0),
            LayoutPoint(x: 11, y: 1),
            LayoutPoint(x: 10, y: 1),
        ])
        let polygonID = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) }?.id
        )
        viewModel.selectedShapeIDs = [polygonID]

        // A handle that does not exist on the geometry must refuse the
        // gesture without recording any state.
        #expect(!viewModel.beginHandleDrag(shapeID: polygonID, handle: .vertex(9)))
        #expect(!viewModel.isDraggingHandle)
        #expect(!viewModel.beginHandleDrag(shapeID: UUID(), handle: .vertex(0)))

        #expect(viewModel.beginHandleDrag(shapeID: polygonID, handle: .vertex(2)))
        viewModel.updateHandleDrag(to: LayoutPoint(x: 0.5, y: 0.5))
        guard case .polygon(let dragged) = try geometry(of: polygonID, in: viewModel) else {
            Issue.record("a polygon vertex drag must stay a polygon")
            return
        }
        #expect(dragged.points[2] == LayoutPoint(x: 11.5, y: 1.5))
        #expect(dragged.points[0] == LayoutPoint(x: 10, y: 0))
        viewModel.endHandleDrag()
        expectDRCMatchesBatchExactly(viewModel, "after vertex drag")
        try expectConnectivityMatchesBatch(viewModel, "after vertex drag")
    }

    // MARK: - Option-drag duplicate

    @Test func duplicatingDragLifecycle() throws {
        let fixture = try Self.makeFixture()
        let viewModel = fixture.viewModel
        let padID = fixture.rich.padB.id
        #expect(!opens(viewModel, net: fixture.rich.netB))

        // Begin: copies land in place, selection moves to them, the
        // originals stay where they are.
        viewModel.selectedShapeIDs = [padID]
        viewModel.beginShapeDrag(duplicating: true)
        #expect(viewModel.isDraggingShapes)
        let copyID = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) }?.id
        )
        #expect(viewModel.selectedShapeIDs == [copyID])

        // Mid-gesture: the copy moves, the original does not, and the
        // disconnected labeled copy reports net B open — live.
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 2.0))
        #expect(
            try geometry(of: padID, in: viewModel) == fixture.rich.padB.geometry,
            "the original must not move during a duplicating drag"
        )
        #expect(
            try geometry(of: copyID, in: viewModel) == fixture.rich.padB.geometry.translated(
                by: LayoutPoint(x: 0, y: 2.0)
            )
        )
        #expect(opens(viewModel, net: fixture.rich.netB))
        try expectConnectivityMatchesBatch(viewModel, "mid duplicating drag")

        // Cancel removes the copies — they did not exist before the
        // gesture, so nothing of them may survive.
        viewModel.cancelShapeDrag()
        #expect(Set(viewModel.documentShapes().map(\.id)) == fixture.initialShapeIDs)
        #expect(!viewModel.selectedShapeIDs.contains(copyID))
        #expect(!opens(viewModel, net: fixture.rich.netB))
        expectDRCMatchesBatchExactly(viewModel, "after cancel")
        try expectConnectivityMatchesBatch(viewModel, "after cancel")

        // End keeps the copy; the whole gesture is one undo step.
        viewModel.selectedShapeIDs = [padID]
        viewModel.beginShapeDrag(duplicating: true)
        let keptID = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) }?.id
        )
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 2.0))
        viewModel.endShapeDrag()
        #expect(
            try geometry(of: keptID, in: viewModel) == fixture.rich.padB.geometry.translated(
                by: LayoutPoint(x: 0, y: 2.0)
            )
        )
        #expect(opens(viewModel, net: fixture.rich.netB))
        expectDRCMatchesBatchExactly(viewModel, "after end")
        try expectConnectivityMatchesBatch(viewModel, "after end")

        viewModel.undo()
        #expect(
            Set(viewModel.documentShapes().map(\.id)) == fixture.initialShapeIDs,
            "begin+move+end must undo as a single step"
        )
        #expect(!opens(viewModel, net: fixture.rich.netB))
        try expectConnectivityMatchesBatch(viewModel, "after undo")
    }
}
