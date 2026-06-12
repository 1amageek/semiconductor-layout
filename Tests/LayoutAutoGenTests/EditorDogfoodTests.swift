import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutIO
import LayoutTech
import LayoutVerify

/// The deferred round-trip, finally run end to end INSIDE the editor: a
/// two-transistor circuit goes from `.subckt` intent to a wired,
/// DRC-clean, LVS-passing layout using goal-level operations only —
/// then survives a GDS round trip (where nets and pins die by format
/// contract) by re-annotating from labels and re-passing LVS.
@MainActor
@Suite("Editor dogfood", .timeLimit(.minutes(3)))
struct EditorDogfoodTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    private static let chainReference = """
    .subckt chain a mid out gnd
    M1 mid a gnd gnd nmos W=2u L=0.18u
    M2 out mid gnd gnd nmos W=2u L=0.18u
    .ends
    """

    @Test func subcktToWiredLVSCleanLayoutAndBackThroughGDS() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let top = LayoutCell(name: "CHAIN")
        let document = LayoutDocument(name: "chain", cells: [top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        viewModel.activeLayer = Self.m1

        // 1. Intent in: two unrealized devices.
        viewModel.loadLVSReference(fromSubckt: Self.chainReference)
        #expect(viewModel.unplacedIntentDevices.count == 2)

        // 2. Ghost-place both through the goal surface. (They cannot
        //    match the reference yet — matching needs the wiring.)
        let first = try #require(viewModel.unplacedIntentDevices.first)
        #expect(viewModel.execute(.placeIntentDevice(deviceID: first.id, at: LayoutPoint(x: 0, y: 0))))
        let second = try #require(viewModel.unplacedIntentDevices.first(where: { $0.id != first.id }))
        #expect(viewModel.execute(.placeIntentDevice(deviceID: second.id, at: LayoutPoint(x: 25, y: 0))))
        let topCell = try #require(viewModel.editor.document.cell(withID: top.id))
        #expect(topCell.instances.count == 2)

        // 3. Name the terminals: a label straight on each terminal bar
        //    (the annotation pass matches flattened geometry), no helper
        //    geometry at all. finish-net does ALL the wiring.
        let pins = viewModel.flattenedDocumentPins()
        func nameTerminal(_ label: String, _ name: String, near x: Double) throws {
            let pin = try #require(
                pins.filter { $0.name == name }
                    .min(by: { abs($0.position.x - x) < abs($1.position.x - x) }),
                "pin \(name) near x=\(x)"
            )
            viewModel.addLabel(text: label, at: pin.position)
        }
        try nameTerminal("a", "gate", near: 0)
        try nameTerminal("mid", "drain", near: 0)
        try nameTerminal("mid", "gate", near: 25)
        try nameTerminal("out", "drain", near: 25)
        try nameTerminal("gnd", "source", near: 0)
        try nameTerminal("gnd", "source", near: 25)
        try nameTerminal("gnd", "bulk", near: 0)
        try nameTerminal("gnd", "bulk", near: 25)

        // Annotation turns the labels into nets, binding instance
        // terminals where the conductor lives inside a child cell; the
        // named-but-split nets (mid, gnd) become opens — and finish-net
        // closes every one under its verification gate.
        let summary = try #require(viewModel.annotateNetsFromLabels())
        #expect(summary.unmatchedLabels.isEmpty, "\(summary.unmatchedLabels)")
        #expect(summary.terminalsBound == 8)
        #expect(summary.unreachableChildElements == 0)
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == false)
        #expect(viewModel.execute(.finishAllNets))
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == true,
                "\(String(describing: viewModel.connectivityAnalysis?.opens))")

        // 4. The whole intent is realized: LVS passes, DRC is clean.
        #expect(viewModel.lvsExtraction?.issues.isEmpty == true,
                "\(String(describing: viewModel.lvsExtraction?.issues))")
        #expect(viewModel.liveLVSPassed == true, "\(String(describing: viewModel.lvsComparison))")
        #expect(viewModel.violations.isEmpty)
        if case .clean = viewModel.trustReport.lvs {} else {
            Issue.record("trust report must show LVS clean")
        }

        // 5. GDS round trip: geometry and labels survive, nets and pins
        //    die by contract — re-annotation brings LVS back.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gds = directory.appendingPathComponent("chain.gds")
        let converter = GDSFormatConverter(tech: tech)
        try converter.exportDocument(viewModel.editor.document, to: gds, format: .gds)
        let reimported = try converter.importDocument(from: gds, format: .gds)

        let reopened = LayoutEditorViewModel(document: reimported, tech: tech)
        reopened.loadLVSReference(fromSubckt: Self.chainReference)
        // Pins and nets died with the format, but extraction reads the
        // surviving labels straight off the conductors they sit on — the
        // reimported layout satisfies the same intent with no editing.
        #expect(
            reopened.liveLVSPassed == true,
            "labels alone must reconnect the intent after the round trip: \(String(describing: reopened.lvsComparison))"
        )

        // Re-annotation persists the labels back into document nets, and
        // LVS still holds on the annotated document.
        let reSummary = try #require(reopened.annotateNetsFromLabels())
        #expect(reSummary.netsCreated == 4, "\(reSummary)")
        #expect(
            reopened.liveLVSPassed == true,
            "after re-annotation the reimported layout must satisfy the same intent: \(String(describing: reopened.lvsComparison))"
        )
    }
}
