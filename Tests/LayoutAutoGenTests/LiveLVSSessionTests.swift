import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

@Suite("Live LVS")
struct LiveLVSSessionTests {
    private let polyLayer = LayoutLayerID(name: "POLY", purpose: "drawing")

    @Test func generatedNmosExtractsKnownDeviceParameters() throws {
        let document = try generatedDocument(kind: "nmos", width: 2.0, length: 0.18)
        let result = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        )

        #expect(result.issues.isEmpty)
        let device = try #require(result.netlist.devices.first)
        #expect(result.netlist.devices.count == 1)
        #expect(device.kind == .nmos)
        #expect(abs(device.parameters.width - 2.0) < 1e-9)
        #expect(abs(device.parameters.length - 0.18) < 1e-9)
        #expect(device.terminals[.gate] == ComparisonNetID("pin:gate"))
        #expect(device.terminals[.source] == ComparisonNetID("pin:source"))
        #expect(device.terminals[.drain] == ComparisonNetID("pin:drain"))
        #expect(device.terminals[.bulk] == ComparisonNetID("pin:bulk"))
    }

    @Test func generatedPmosExtractsKnownDeviceKind() throws {
        let document = try generatedDocument(kind: "pmos", width: 3.0, length: 0.25)
        let result = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        )

        #expect(result.issues.isEmpty)
        let device = try #require(result.netlist.devices.first)
        #expect(result.netlist.devices.count == 1)
        #expect(device.kind == .pmos)
        #expect(abs(device.parameters.width - 3.0) < 1e-9)
        #expect(abs(device.parameters.length - 0.25) < 1e-9)
    }

    @Test func generatedMultiFingerMosfetExtractsMultiplier() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18, "nf": 4.0],
            tech: tech
        )
        let document = LayoutDocument(name: "mos", cells: [cell], topCellID: cell.id)

        let result = try DeviceExtractor().extract(document: document, tech: tech)

        #expect(result.issues.isEmpty)
        #expect(result.netlist.devices.count == 1)
        let device = try #require(result.netlist.devices.first)
        #expect(device.parameters.multiplier == 4)
        #expect(abs(device.parameters.width - 2.0) < 1e-9)
        #expect(abs(device.parameters.length - 0.18) < 1e-9)
    }

    @Test func comparatorTreatsSourceDrainAsSymmetric() throws {
        let document = try generatedDocument(kind: "nmos", width: 2.0, length: 0.18)
        let extracted = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        ).netlist
        var referenceDevice = try #require(extracted.devices.first)
        referenceDevice.terminals[.source] = extracted.devices[0].terminals[.drain]
        referenceDevice.terminals[.drain] = extracted.devices[0].terminals[.source]
        let reference = ComparisonNetlist(devices: [referenceDevice], ports: extracted.ports)

        let comparison = NetlistComparator().compare(extracted: extracted, reference: reference)

        #expect(comparison.passed)
    }

    @Test func liveSessionReportsParameterMismatchAndClearsAfterUndoDelta() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        var document = try generatedDocument(kind: "nmos", width: 2.0, length: 0.18)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let session = try LiveLVSSession(document: document, tech: tech, reference: reference)
        #expect(session.passed)

        var cell = try #require(document.cells.first)
        let polyIndex = try #require(cell.shapes.firstIndex { $0.layer == polyLayer })
        let original = cell.shapes[polyIndex]
        var widened = original
        guard case .rect(let rect) = widened.geometry else {
            Issue.record("Generated POLY should be rectangular")
            return
        }
        widened.geometry = .rect(LayoutRect(
            origin: rect.origin,
            size: LayoutSize(width: rect.size.width + 0.05, height: rect.size.height)
        ))

        let broken = try session.apply(LayoutEditDelta(updatedShapes: [widened]))
        #expect(!broken.passed)
        #expect(broken.comparison.parameterMismatches.count == 1)

        cell.shapes[polyIndex] = widened
        document.updateCell(cell)
        let healed = try session.apply(LayoutEditDelta(updatedShapes: [original]))
        #expect(healed.passed)
    }

    @Test func disconnectedGateContactFailsLVS() throws {
        // The old pin-proximity heuristic resolved the gate net by the
        // NEAREST gate pin, so physically disconnecting the gate changed
        // nothing — a silent false pass. Connectivity-based terminals must
        // see the break.
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try generatedDocument(kind: "nmos", width: 2.0, length: 0.18)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let session = try LiveLVSSession(document: document, tech: tech, reference: reference)
        #expect(session.passed)

        let cell = try #require(document.cells.first)
        let cutLayer = try #require(tech.contactDefinition(for: "CONT_POLY")?.cutLayer)
        let poly = try #require(cell.shapes.first { $0.layer == polyLayer })
        let polyBox = LayoutGeometryAnalysis.boundingBox(for: poly.geometry)
        let gateContact = try #require(cell.shapes.first { shape in
            shape.layer == cutLayer
                && LayoutGeometryAnalysis.boundingBox(for: shape.geometry).intersects(polyBox)
        })

        let update = try session.apply(LayoutEditDelta(removedShapeIDs: [gateContact.id]))

        #expect(!update.passed)
        #expect(!update.comparison.unmatchedExtractedDevices.isEmpty)
        #expect(!update.comparison.unmatchedReferenceDevices.isEmpty)
    }

    @Test func rotatedInstanceExtractsSameDeviceParameters() throws {
        // A device cell placed with a 90-degree rotation flattens into
        // axis-aligned 4-point polygons with the channel crossing the
        // OTHER axis. Orientation-aware recognition must still find one
        // device with the same W/L and connected terminals.
        let tech = LayoutTechDatabase.sampleProcess()
        let deviceCell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18],
            tech: tech
        )
        let instance = LayoutInstance(
            cellID: deviceCell.id,
            name: "X0",
            transform: LayoutTransform(rotation: .deg90)
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(
            name: "rotated",
            cells: [deviceCell, top],
            topCellID: top.id
        )

        let result = try DeviceExtractor().extract(document: document, tech: tech)

        #expect(result.issues.isEmpty)
        #expect(result.netlist.devices.count == 1)
        let device = try #require(result.netlist.devices.first)
        #expect(abs(device.parameters.width - 2.0) < 1e-9)
        #expect(abs(device.parameters.length - 0.18) < 1e-9)
        #expect(device.terminals[.gate] == ComparisonNetID("pin:gate"))
    }

    @Test func duplicatePortNamesReportConflictInsteadOfTrapping() throws {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let left = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
        )
        let right = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 5, y: 0),
                size: LayoutSize(width: 1, height: 1)
            ))
        )
        func pin(_ name: String, x: Double) -> LayoutPin {
            LayoutPin(
                name: name,
                position: LayoutPoint(x: x, y: 0.5),
                size: LayoutSize(width: 0.2, height: 0.2),
                layer: m1
            )
        }
        // Two pins named A on two disconnected islands: a conflict report,
        // not a crash. Two pins named B on ONE island: no conflict.
        let cell = LayoutCell(
            name: "TOP",
            shapes: [left, right],
            pins: [pin("A", x: 0.5), pin("A", x: 5.5), pin("B", x: 0.3), pin("B", x: 0.7)]
        )
        let document = LayoutDocument(name: "ports", cells: [cell], topCellID: cell.id)

        let result = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        )

        #expect(result.issues.contains { $0.kind == .conflictingPort && $0.message.contains("'A'") })
        #expect(!result.issues.contains { $0.kind == .conflictingPort && $0.message.contains("'B'") })
    }

    @Test func terminalConflictsBecomeExtractionIssues() throws {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let childShape = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: .zero,
                size: LayoutSize(width: 1, height: 1)
            ))
        )
        let child = LayoutCell(
            name: "SHORTED_TERMINALS",
            shapes: [childShape],
            pins: [
                LayoutPin(
                    name: "A",
                    position: LayoutPoint(x: 0.3, y: 0.5),
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: m1
                ),
                LayoutPin(
                    name: "B",
                    position: LayoutPoint(x: 0.7, y: 0.5),
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: m1
                ),
            ]
        )
        let netA = LayoutNet(name: "A")
        let netB = LayoutNet(name: "B")
        let instance = LayoutInstance(
            cellID: child.id,
            name: "X0",
            terminalNetIDs: ["A": netA.id, "B": netB.id]
        )
        let top = LayoutCell(
            name: "TOP",
            instances: [instance],
            nets: [netA, netB]
        )
        let document = LayoutDocument(name: "terminal-conflict", cells: [child, top], topCellID: top.id)

        let result = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        )

        #expect(result.issues.contains {
            $0.kind == .shortedNet && $0.message.contains("Instance terminal mapping")
        })
    }

    @Test func extractionIssuesCarryPolicyAwareDiagnostics() throws {
        let activeLayer = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let polyLayer = LayoutLayerID(name: "POLY", purpose: "drawing")
        let active = LayoutShape(
            layer: activeLayer,
            geometry: .rect(LayoutRect(
                origin: .zero,
                size: LayoutSize(width: 2.0, height: 1.0)
            ))
        )
        let poly = LayoutShape(
            layer: polyLayer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.9, y: -0.1),
                size: LayoutSize(width: 0.2, height: 1.2)
            ))
        )
        let cell = LayoutCell(name: "AMBIGUOUS_MOS", shapes: [active, poly])
        let document = LayoutDocument(name: "ambiguous-mos", cells: [cell], topCellID: cell.id)

        let result = try DeviceExtractor().extract(
            document: document,
            tech: LayoutTechDatabase.sampleProcess()
        )

        #expect(result.netlist.devices.isEmpty)
        let issue = try #require(result.issues.first)
        #expect(issue.kind == .ambiguousDeviceType)
        #expect(issue.severity == .error)
        #expect(issue.code == "layout.extraction.ambiguous-device-type")
        #expect(issue.policyApplicability == .layerMappingReviewRequired)
        #expect(issue.affectedLayers.map(DeviceExtractionSummary.layerIdentifier) == [
            "ACTIVE/drawing",
            "NIMP/drawing",
            "PIMP/drawing",
            "POLY/drawing",
        ])
        #expect(issue.suggestedActions.contains("fix-implant-coverage"))
        #expect(issue.suggestedActions.contains("review-device-extraction-profile"))
        #expect(result.summary.issueCount == 1)
        #expect(result.summary.errorCount == 1)
        #expect(result.summary.issueCountsByKind["ambiguousDeviceType"] == 1)
        #expect(result.summary.issueCountsByCode["layout.extraction.ambiguous-device-type"] == 1)
        #expect(result.summary.issueCountsByPolicyApplicability["layerMappingReviewRequired"] == 1)
        #expect(result.summary.affectedLayers == [
            "ACTIVE/drawing",
            "NIMP/drawing",
            "PIMP/drawing",
            "POLY/drawing",
        ])
        #expect(result.summary.suggestedActions.contains("review-device-extraction-profile"))
    }

    @Test func extractionIssueArtifactsRejectMissingPolicySummary() throws {
        let incompleteJSON = """
        {
          "netlist": {
            "devices": [],
            "ports": {}
          },
          "issues": [
            {
              "kind": "missingTerminal",
              "message": "incomplete terminal issue",
              "region": {
                "origin": { "x": 0, "y": 0 },
                "size": { "width": 1, "height": 1 }
              },
              "shapeIDs": []
            }
          ]
        }
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DeviceExtractionResult.self,
                from: Data(incompleteJSON.utf8)
            )
        }
    }

    @Test func comparatorPairsParameterExactCandidateOverFirstTopologicalOne() {
        func device(_ id: String, width: Double) -> ComparisonNetlist.Device {
            ComparisonNetlist.Device(
                id: id,
                kind: .nmos,
                terminals: [
                    .gate: ComparisonNetID("net:g"),
                    .source: ComparisonNetID("net:s"),
                    .drain: ComparisonNetID("net:d"),
                    .bulk: ComparisonNetID("net:b"),
                ],
                parameters: ComparisonDeviceParameters(width: width, length: 0.18),
                region: LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1))
            )
        }
        // Two reference devices share one topology key and differ only in
        // width. Whatever order the extracted side arrives in, each must
        // pair with its parameter-exact counterpart — no mismatch reports.
        let reference = ComparisonNetlist(devices: [device("r1", width: 1.0), device("r2", width: 2.0)])
        let extracted = ComparisonNetlist(devices: [device("x2", width: 2.0), device("x1", width: 1.0)])

        let comparison = NetlistComparator().compare(extracted: extracted, reference: reference)

        #expect(comparison.passed)
        #expect(comparison.parameterMismatches.isEmpty)
    }

    @Test func comparatorReportsPortMismatches() {
        let extracted = ComparisonNetlist(
            devices: [],
            ports: ["A": ComparisonNetID("pin:A")]
        )
        let reference = ComparisonNetlist(
            devices: [],
            ports: [
                "A": ComparisonNetID("pin:B"),
                "B": ComparisonNetID("pin:B"),
            ]
        )

        let comparison = NetlistComparator().compare(extracted: extracted, reference: reference)

        #expect(!comparison.passed)
        #expect(comparison.portMismatches.map(\.portName) == ["A", "B"])
    }

    @Test func emptyDeltaReportsSkippedComparison() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try generatedDocument(kind: "nmos", width: 1.5, length: 0.2)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let session = try LiveLVSSession(document: document, tech: tech, reference: reference)

        let update = try session.apply(LayoutEditDelta())

        #expect(update.skippedComparison)
        #expect(update.passed)
    }

    @Test func duplicateShapeAddIsRejectedBeforeExtraction() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try generatedDocument(kind: "nmos", width: 1.5, length: 0.2)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let session = try LiveLVSSession(document: document, tech: tech, reference: reference)
        let existing = try #require(document.cells.first?.shapes.first)

        #expect(throws: LayoutEditDeltaValidationError.duplicateShapeID(existing.id)) {
            try session.apply(LayoutEditDelta(addedShapes: [existing]))
        }
        #expect(session.passed)
    }

    @Test func conflictingShapeDeltaEntryIsRejectedBeforeMutation() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try generatedDocument(kind: "nmos", width: 1.5, length: 0.2)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let session = try LiveLVSSession(document: document, tech: tech, reference: reference)
        let existing = try #require(document.cells.first?.shapes.first)

        #expect(throws: LayoutEditDeltaValidationError.conflictingDeltaEntry(existing.id)) {
            try session.apply(LayoutEditDelta(
                updatedShapes: [existing],
                removedShapeIDs: [existing.id]
            ))
        }
        #expect(session.passed)
    }

    @MainActor
    @Test func editorViewModelTracksLiveLVSOnEditAndUndo() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let document = try generatedDocument(kind: "nmos", width: 2.0, length: 0.18)
        let reference = try DeviceExtractor().extract(document: document, tech: tech).netlist
        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        viewModel.setLVSReference(reference)
        #expect(viewModel.liveLVSPassed == true)

        let poly = try #require(viewModel.documentShapes().first { $0.layer == polyLayer })
        viewModel.selectedShapeIDs = [poly.id]
        viewModel.deleteSelectedShapes()

        #expect(viewModel.liveLVSPassed == false)
        #expect(viewModel.lvsComparison?.unmatchedReferenceDevices.count == 1)

        viewModel.undo()
        #expect(viewModel.liveLVSPassed == true)
    }

    @MainActor
    @Test func editorViewModelRebuildsLiveLVSAfterAddingLabel() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        var cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18],
            tech: tech
        )
        let gatePin = try #require(cell.pins.first { $0.role == .gate })
        cell.pins.removeAll()
        cell.labels.removeAll()
        let document = LayoutDocument(name: "label-driven-lvs", cells: [cell], topCellID: cell.id)

        let baseline = try DeviceExtractor().extract(document: document, tech: tech).netlist
        var referenceDevice = try #require(baseline.devices.first)
        #expect(referenceDevice.terminals[.gate] != ComparisonNetID("pin:gate"))
        referenceDevice.terminals[.gate] = ComparisonNetID("pin:gate")
        let reference = ComparisonNetlist(devices: [referenceDevice])

        let viewModel = LayoutEditorViewModel(document: document, tech: tech)
        viewModel.setLVSReference(reference)
        #expect(viewModel.liveLVSPassed == false)

        viewModel.activeLayer = gatePin.layer
        viewModel.addLabel(text: "gate", at: gatePin.position)

        let device = try #require(viewModel.lvsExtraction?.netlist.devices.first)
        #expect(device.terminals[.gate] == ComparisonNetID("pin:gate"))
        #expect(viewModel.liveLVSPassed == true)
    }

    private func generatedDocument(
        kind: String,
        width: Double,
        length: Double
    ) throws -> LayoutDocument {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: kind,
            instanceName: "M1",
            parameters: ["w": width, "l": length],
            tech: tech
        )
        return LayoutDocument(name: "mos", cells: [cell], topCellID: cell.id)
    }
}
