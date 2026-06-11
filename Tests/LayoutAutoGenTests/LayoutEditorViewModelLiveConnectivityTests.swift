import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
import LayoutEditor

/// Contract of the view model's live-connectivity plumbing: after every
/// editing operation (including transient drag mirrors and undo/redo) the
/// published `connectivityAnalysis` must equal a from-scratch batch
/// extraction of the current document; disabling the channel yields an
/// explicit `nil`, never a silently stale analysis; and the net highlight
/// anchor re-resolves against the live analysis so it follows the
/// conductor through edits.
@MainActor
@Suite("LayoutEditorViewModel live connectivity", .timeLimit(.minutes(5)))
struct LayoutEditorViewModelLiveConnectivityTests {

    private struct Fixture {
        var viewModel: LayoutEditorViewModel
        var rich: IncrementalDRCEquivalenceHarness.RichFixture
        /// Shape IDs present in the active cell before any edit.
        var initialShapeIDs: Set<UUID>
    }

    private static func makeFixture() -> Fixture {
        let rich = IncrementalDRCEquivalenceHarness.makeRichFixture()
        let viewModel = LayoutEditorViewModel(document: rich.document, tech: rich.tech)
        return Fixture(
            viewModel: viewModel,
            rich: rich,
            initialShapeIDs: Set(viewModel.documentShapes().map(\.id))
        )
    }

    private func expectLiveMatchesBatch(
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

    /// True when the analysis contains a conductor piece shorting both
    /// fixture nets together.
    private func shortsNetANetB(_ analysis: ConnectivityAnalysis?, _ fixture: Fixture) -> Bool {
        analysis?.shorts.contains {
            Set($0.netIDs).isSuperset(of: [fixture.rich.netA, fixture.rich.netB])
        } ?? false
    }

    private func opensNetB(_ analysis: ConnectivityAnalysis?, _ fixture: Fixture) -> Bool {
        analysis?.opens.contains { $0.netID == fixture.rich.netB } ?? false
    }

    // MARK: - Discrete edits

    @Test func discreteEditsKeepLiveAnalysisExact() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        try expectLiveMatchesBatch(viewModel, "initial")
        #expect(!shortsNetANetB(viewModel.connectivityAnalysis, fixture))

        // An unlabeled M1 strap touching both wire A and wire B fuses the
        // two conductors: a short DRC's pairwise overlap check cannot see.
        viewModel.activeLayer = fixture.rich.m1
        viewModel.addRectangle(
            from: LayoutPoint(x: 7.0, y: 0.2),
            to: LayoutPoint(x: 7.4, y: 1.7)
        )
        try expectLiveMatchesBatch(viewModel, "addRectangle bridge")
        #expect(shortsNetANetB(viewModel.connectivityAnalysis, fixture))

        let bridgeID = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) }?.id
        )
        viewModel.selectedShapeIDs = [bridgeID]
        viewModel.deleteSelectedShapes()
        try expectLiveMatchesBatch(viewModel, "deleteSelectedShapes")
        #expect(!shortsNetANetB(viewModel.connectivityAnalysis, fixture))

        // Structural edits resync the session rather than corrupting it.
        viewModel.addPin(
            name: "A",
            at: LayoutPoint(x: 0.2, y: 0.2),
            size: LayoutSize(width: 0.1, height: 0.1)
        )
        try expectLiveMatchesBatch(viewModel, "addPin")
    }

    // MARK: - Interactive drag

    @Test func dragStrandsAndHealsTheNetLive() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        #expect(!opensNetB(viewModel.connectivityAnalysis, fixture))

        // Dragging pad B off its via strands it: the open must appear
        // mid-gesture, while the pointer is still down.
        viewModel.selectedShapeIDs = [fixture.rich.padB.id]
        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 2.0))
        #expect(opensNetB(viewModel.connectivityAnalysis, fixture))
        try expectLiveMatchesBatch(viewModel, "mid-drag stranded")

        // Dragging back over the via heals the net before the gesture ends.
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 0))
        #expect(!opensNetB(viewModel.connectivityAnalysis, fixture))
        viewModel.endShapeDrag()
        try expectLiveMatchesBatch(viewModel, "after drag")

        // A cancelled drag restores the origin and its verdict.
        viewModel.beginShapeDrag()
        viewModel.updateShapeDrag(to: LayoutPoint(x: 0, y: 2.0))
        #expect(opensNetB(viewModel.connectivityAnalysis, fixture))
        viewModel.cancelShapeDrag()
        #expect(!opensNetB(viewModel.connectivityAnalysis, fixture))
        try expectLiveMatchesBatch(viewModel, "after cancel")
    }

    // MARK: - Channel independence

    @Test func connectivityRunsIndependentlyOfDRDMode() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.drdMode = .off
        let frozenViolations = viewModel.violations

        viewModel.selectedShapeIDs = [fixture.rich.padB.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 2.0))
        #expect(
            viewModel.violations == frozenViolations,
            "with DRD off, edits must not update violations"
        )
        #expect(
            opensNetB(viewModel.connectivityAnalysis, fixture),
            "connectivity is its own channel and must stay live with DRD off"
        )
        try expectLiveMatchesBatch(viewModel, "edit with DRD off")
    }

    @Test func disablingLiveConnectivityIsExplicitlyUnavailable() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        #expect(viewModel.connectivityAnalysis != nil)

        viewModel.liveConnectivityEnabled = false
        #expect(viewModel.connectivityAnalysis == nil, "disabled means nil, not stale")
        #expect(viewModel.flylines.isEmpty)

        viewModel.selectedShapeIDs = [fixture.rich.padB.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 2.0))
        #expect(
            viewModel.connectivityAnalysis == nil,
            "edits while disabled must not resurrect a stale analysis"
        )

        viewModel.liveConnectivityEnabled = true
        try expectLiveMatchesBatch(viewModel, "after re-enabling")
        #expect(opensNetB(viewModel.connectivityAnalysis, fixture))
    }

    // MARK: - Undo/redo

    @Test func undoRedoResyncLiveAnalysis() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel
        viewModel.selectedShapeIDs = [fixture.rich.padB.id]
        viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 2.0))
        #expect(opensNetB(viewModel.connectivityAnalysis, fixture))

        viewModel.undo()
        #expect(!opensNetB(viewModel.connectivityAnalysis, fixture))
        try expectLiveMatchesBatch(viewModel, "after undo")

        viewModel.redo()
        #expect(opensNetB(viewModel.connectivityAnalysis, fixture))
        try expectLiveMatchesBatch(viewModel, "after redo")
    }

    // MARK: - Net highlight

    @Test func netHighlightAnchorFollowsTheConductor() throws {
        let fixture = Self.makeFixture()
        let viewModel = fixture.viewModel

        viewModel.highlightNet(ofShape: fixture.rich.wireA.id)
        let initial = try #require(viewModel.highlightedNet)
        #expect(initial.shapeIDs.contains(fixture.rich.wireA.id))
        #expect(
            !initial.shapeIDs.contains(fixture.rich.padB.id),
            "nets A and B start as separate conductors"
        )

        // Bridging the wires fuses the conductors; the anchored highlight
        // must re-resolve to the grown piece without re-anchoring.
        viewModel.activeLayer = fixture.rich.m1
        viewModel.addRectangle(
            from: LayoutPoint(x: 7.0, y: 0.2),
            to: LayoutPoint(x: 7.4, y: 1.7)
        )
        let bridged = try #require(viewModel.highlightedNet)
        #expect(bridged.shapeIDs.contains(fixture.rich.wireA.id))
        #expect(bridged.shapeIDs.contains(fixture.rich.padB.id))
        #expect(Set(bridged.declaredNetIDs).isSuperset(of: [fixture.rich.netA, fixture.rich.netB]))

        // A via anchor resolves through its member list the same way.
        viewModel.highlightNet(ofVia: fixture.rich.viaB.id)
        let viaAnchored = try #require(viewModel.highlightedNet)
        #expect(viaAnchored.viaIDs.contains(fixture.rich.viaB.id))
        #expect(viaAnchored.shapeIDs.contains(fixture.rich.wireA.id))

        // Removing the bridge shrinks the conductor under the same anchor.
        let bridgeID = try #require(
            viewModel.documentShapes().first { !fixture.initialShapeIDs.contains($0.id) }?.id
        )
        viewModel.selectedShapeIDs = [bridgeID]
        viewModel.deleteSelectedShapes()
        let split = try #require(viewModel.highlightedNet)
        #expect(split.viaIDs.contains(fixture.rich.viaB.id))
        #expect(!split.shapeIDs.contains(fixture.rich.wireA.id))

        viewModel.clearNetHighlight()
        #expect(viewModel.highlightedNet == nil)

        // No analysis, no highlight — the anchor never resolves against
        // stale data.
        viewModel.highlightNet(ofVia: fixture.rich.viaB.id)
        viewModel.liveConnectivityEnabled = false
        #expect(viewModel.highlightedNet == nil)
    }
}
