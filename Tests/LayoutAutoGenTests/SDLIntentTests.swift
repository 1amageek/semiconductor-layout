import Foundation
import Testing
import LayoutCore
import LayoutAutoGen
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

    @Test func generatedMOSAnnotationPreservesChannelSeparationAndSourceMeaning() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        var cell = try MOSFETCellGenerator().generateCell(deviceKindID: "nmos", instanceName: "device",
            parameters: ["w": 2, "l": 0.18, "nf": 1], tech: tech)
        let names: [LayoutPinRole: String] = [.source: "S", .drain: "D", .gate: "G", .bulk: "B"]
        cell.labels = try cell.pins.map { pin in
            LayoutLabel(text: try #require(names[pin.role]), position: pin.position, layer: pin.layer)
        }
        let document = LayoutDocument(name: "native-annotation", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        let summary = try #require(viewModel.annotateNetsFromLabels(requireAllLabels: true),
            "Annotation failed: \(viewModel.lastError ?? "no error")")
        #expect(summary.unmatchedLabels.isEmpty && summary.pinsAnnotated == 4)
        let annotated = try #require(viewModel.editor.document.cell(withID: cell.id))
        let netByName = Dictionary(uniqueKeysWithValues: annotated.nets.map { ($0.name, $0.id) })
        for pin in annotated.pins { #expect(pin.netID == netByName[try #require(names[pin.role])]) }
        // One ACTIVE source crosses the channel. Its native slabs may have
        // different names, so annotation must not relabel the whole source.
        for shape in cell.shapes where shape.layer.name == "ACTIVE" {
            #expect(annotated.shapes.first { $0.id == shape.id }?.geometry == shape.geometry)
        }
        let snapshot = try DeviceExtractor().captureConductors(document: viewModel.editor.document, tech: tech)
        #expect(snapshot.electricalContext == .deviceAwareMOS)
        for source in snapshot.hierarchy.shapes.indices {
            let components = snapshot.components.indices.filter { index in
                snapshot.components[index].footprintIndices.contains { snapshot.footprints[$0].source == .shape(source) }
            }
            if components.count > 1 {
                let original = snapshot.hierarchy.shapes[source]
                #expect(annotated.shapes.first { $0.id == original.id }?.netID == cell.shapes.first { $0.id == original.id }?.netID)
            }
        }
        #expect(snapshot.shortComponentIndices.isEmpty)
        let extraction = try DeviceExtractor().extract(document: viewModel.editor.document, tech: tech)
        let device = try #require(extraction.netlist.devices.first)
        #expect(device.terminals[.source]?.rawValue == "pin:S")
        #expect(device.terminals[.drain]?.rawValue == "pin:D")
        #expect(device.terminals[.source] != device.terminals[.drain])
        #expect(viewModel.connectivityAnalysis?.sourceSnapshot?.electricalContext == .deviceAwareMOS)
        viewModel.undo()
        #expect(viewModel.editor.document == document)
    }

    @Test func repeatedSourceUUIDsBindExactDistinctInstances() throws {
        let child = Self.terminalCell()
        let first = LayoutInstance(cellID: child.id, name: "first")
        let second = LayoutInstance(cellID: child.id, name: "second", transform: .init(translation: .init(x: 10, y: 0)))
        let top = LayoutCell(name: "TOP", labels: Self.terminalLabels(), instances: [first, second])
        let document = LayoutDocument(name: "scoped-labels", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        let summary = try #require(viewModel.annotateNetsFromLabels(requireAllLabels: true))
        #expect(summary.terminalsBound == 2 && summary.unmatchedLabels.isEmpty)
        let changed = try #require(viewModel.editor.document.cell(withID: top.id))
        let names = Dictionary(uniqueKeysWithValues: changed.nets.map { ($0.name, $0.id) })
        #expect(changed.instances.first { $0.id == first.id }?.terminalNetIDs["P"] == names["A"])
        #expect(changed.instances.first { $0.id == second.id }?.terminalNetIDs["P"] == names["B"])
        #expect(viewModel.editor.document.cell(withID: child.id) == child)
        let capture = try DeviceExtractor().captureConductors(document: viewModel.editor.document, tech: .standard())
        #expect(capture.shortComponentIndices.isEmpty)
        #expect(Set(capture.pins.compactMap(\.declaredNet)).count == 2)
    }

    @Test func conflictingSharedArrayTerminalIsRejectedAtomically() throws {
        let child = Self.terminalCell()
        let instance = LayoutInstance(cellID: child.id, name: "array", repetition: .init(columns: 2, rows: 1,
            columnStep: .init(x: 10, y: 0), rowStep: .zero))
        let top = LayoutCell(name: "TOP", labels: Self.terminalLabels(), instances: [instance])
        let document = LayoutDocument(name: "array-labels", cells: [child, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        #expect(viewModel.annotateNetsFromLabels(requireAllLabels: true) == nil)
        #expect(viewModel.lastError == SDLNetAnnotationError.conflictingTerminalBinding(instance: instance.id, pin: "P").errorDescription)
        #expect(viewModel.editor.document == document)
    }

    @Test func strictGoalDoesNotPartiallyAnnotateUnmatchedRequestedLabels() throws {
        var cell = Self.terminalCell()
        cell.labels = [LayoutLabel(text: "matched", position: .init(x: 0.5, y: 0.2), layer: Self.m1),
                       LayoutLabel(text: "ghost", position: .init(x: 20, y: 20), layer: Self.m1)]
        let document = LayoutDocument(name: "strict-labels", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        #expect(!viewModel.execute(.annotateNetsFromLabels))
        #expect(viewModel.goalLog.last?.succeeded == false)
        #expect(viewModel.lastError == SDLNetAnnotationError.unmatchedLabels(["ghost"]).errorDescription)
        #expect(viewModel.editor.document == document)
    }

    @Test func conflictingComponentNamesDoNotCreateAnyNets() throws {
        var cell = Self.terminalCell()
        cell.labels = [LayoutLabel(text: "A", position: .init(x: 0.3, y: 0.2), layer: Self.m1),
                       LayoutLabel(text: "B", position: .init(x: 0.7, y: 0.2), layer: Self.m1)]
        let document = LayoutDocument(name: "conflicting-labels", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        #expect(viewModel.annotateNetsFromLabels() == nil)
        #expect(viewModel.lastError == SDLNetAnnotationError.conflictingComponentNames(["A", "B"]).errorDescription)
        #expect(viewModel.editor.document == document)
    }

    @Test func nestedTerminalWithoutRootCorrespondenceIsRejectedAtomically() throws {
        let child = Self.terminalCell()
        let inner = LayoutInstance(cellID: child.id, name: "inner")
        let middle = LayoutCell(name: "middle", instances: [inner])
        let outer = LayoutInstance(cellID: middle.id, name: "outer")
        let top = LayoutCell(name: "TOP", labels: [Self.terminalLabels()[0]], instances: [outer])
        let document = LayoutDocument(name: "nested-labels", cells: [child, middle, top], topCellID: top.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        #expect(viewModel.annotateNetsFromLabels(requireAllLabels: true) == nil)
        #expect(viewModel.lastError == SDLNetAnnotationError.unavailableTerminalBinding(
            pin: "P", instancePath: [outer.id, inner.id]).errorDescription)
        #expect(viewModel.editor.document == document)
    }

    @Test func annotationPointProbeBudgetIsAdmittedBeforeMutation() throws {
        var cell = Self.terminalCell()
        cell.labels = (0..<10).map { _ in Self.terminalLabels()[0] }
        let document = LayoutDocument(name: "bounded-labels", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: .standard())
        let limits = LayoutConductorCaptureLimits(maximumContactProbes: 4)
        #expect(viewModel.annotateNetsFromLabels(requireAllLabels: true, limits: limits) == nil)
        #expect(viewModel.lastError == SDLNetAnnotationError.pointProbeLimitExceeded.errorDescription)
        #expect(viewModel.editor.document == document)
    }

    private static func terminalCell() -> LayoutCell {
        LayoutCell(name: "terminal", shapes: [.init(layer: m1, geometry: .rect(.init(origin: .zero, size: .init(width: 1, height: 0.4))))],
            pins: [.init(name: "P", position: .init(x: 0.5, y: 0.2), size: .init(width: 0.2, height: 0.2), layer: m1)])
    }

    private static func terminalLabels() -> [LayoutLabel] {
        [.init(text: "A", position: .init(x: 0.5, y: 0.2), layer: m1),
         .init(text: "B", position: .init(x: 10.5, y: 0.2), layer: m1)]
    }

}
