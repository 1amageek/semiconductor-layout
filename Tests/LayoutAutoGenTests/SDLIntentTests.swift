import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// N2 contract: the reference netlist is a first-class editing input.
/// Unrealized devices are listed and placeable with one click; label
/// text turns imported (net-less) geometry into named nets so the whole
/// verification stack engages; the convergence meter tracks progress.
@MainActor
@Suite("SDL intent", .timeLimit(.minutes(2)))
struct SDLIntentTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    /// The end-to-end loop: load intent → device is listed unplaced →
    /// one armed click realizes it → the meter converges and LVS passes.
    @Test func placingTheArmedIntentDeviceConvergesLVS() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let empty = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "sdl", cells: [empty], topCellID: empty.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)

        viewModel.loadLVSReference(fromSubckt: """
        .subckt mos source gate drain bulk
        M1 drain gate source bulk nmos W=2u L=0.18u
        .ends
        """)

        let comparison = try #require(viewModel.lvsComparison)
        #expect(comparison.referenceDeviceCount == 1)
        #expect(comparison.matchedReferenceDeviceCount == 0)
        let unplaced = try #require(viewModel.unplacedIntentDevices.first)

        viewModel.armIntentPlacement(unplaced)
        #expect(viewModel.pendingIntentDevice?.id == unplaced.id)
        viewModel.placeArmedIntentDevice(at: LayoutPoint(x: 0, y: 0))

        #expect(viewModel.pendingIntentDevice == nil)
        let converged = try #require(viewModel.lvsComparison)
        #expect(converged.matchedReferenceDeviceCount == 1)
        #expect(viewModel.unplacedIntentDevices.isEmpty)
        #expect(viewModel.liveLVSPassed == true, "the placed generator cell realizes the intent exactly")
    }

    /// Placing the same device parameters twice reuses one generated cell.
    @Test func repeatedIntentPlacementReusesTheGeneratedCell() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let empty = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "sdl", cells: [empty], topCellID: empty.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)

        viewModel.loadLVSReference(fromSubckt: """
        .subckt pair s1 g1 d1 s2 g2 d2 b
        M1 d1 g1 s1 b nmos W=2u L=0.18u
        M2 d2 g2 s2 b nmos W=2u L=0.18u
        .ends
        """)
        #expect(viewModel.unplacedIntentDevices.count == 2)
        let cellCountBefore = viewModel.editor.document.cells.count

        let first = try #require(viewModel.unplacedIntentDevices.first)
        viewModel.armIntentPlacement(first)
        viewModel.placeArmedIntentDevice(at: LayoutPoint(x: 0, y: 0))
        let second = try #require(viewModel.unplacedIntentDevices.first)
        viewModel.armIntentPlacement(second)
        viewModel.placeArmedIntentDevice(at: LayoutPoint(x: 20, y: 0))

        #expect(
            viewModel.editor.document.cells.count == cellCountBefore + 1,
            "identical W/L/m devices share one generated cell"
        )
        let top = try #require(viewModel.editor.document.cell(withID: empty.id))
        #expect(top.instances.count == 2)
    }

    /// Imported-GDS workflow: geometry with labels but no nets. The
    /// annotation pass names the islands; split nets become visible as
    /// opens — the intent flylines.
    @Test func labelAnnotationNamesIslandsAndExposesIntentOpens() throws {
        let left = LayoutShape(
            layer: Self.m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 2, height: 0.4)))
        )
        let right = LayoutShape(
            layer: Self.m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 5, y: 0),
                size: LayoutSize(width: 2, height: 0.4)
            ))
        )
        let labels = [
            LayoutLabel(text: "A", position: LayoutPoint(x: 0.5, y: 0.2), layer: Self.m1),
            LayoutLabel(text: "A", position: LayoutPoint(x: 5.5, y: 0.2), layer: Self.m1),
        ]
        let cell = LayoutCell(name: "TOP", shapes: [left, right], labels: labels)
        let document = LayoutDocument(name: "import", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == true,
                "without nets there is nothing to be open")

        let summary = try #require(viewModel.annotateNetsFromLabels())

        #expect(summary.netsCreated == 1, "two labels with one text are one net")
        #expect(summary.shapesAnnotated == 2)
        #expect(summary.unmatchedLabels.isEmpty)
        let analysis = try #require(viewModel.connectivityAnalysis)
        #expect(
            analysis.opens.count == 1,
            "the named-but-disconnected net is now an open — the intent flyline"
        )
        #expect(!analysis.flylines.isEmpty)

        viewModel.undo()
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == true,
                "annotation is one undoable edit")
    }

    @Test func labelOnEmptySpaceIsReportedNotSilentlySkipped() throws {
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: Self.m1,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
                )
            ],
            labels: [
                LayoutLabel(text: "GHOST", position: LayoutPoint(x: 50, y: 50), layer: Self.m1)
            ]
        )
        let document = LayoutDocument(name: "ghost", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())

        let summary = try #require(viewModel.annotateNetsFromLabels())

        #expect(summary.unmatchedLabels == ["GHOST"])
        #expect(summary.netsCreated == 0)
    }
}
