import Foundation
import LayoutCore
import LayoutTech
import LayoutAutoGen
import Testing
@testable import LayoutVerify

@Suite("Explicit finite-resistance body connectivity", .timeLimit(.minutes(1)))
struct PassiveDeviceConnectivityTests {
    private let poly = ResistorCellGenerator.polyLayerID
    private let marker = ResistorCellGenerator.bodyMarkerLayerID
    private var context: LayoutElectricalContext { .deviceAwareMOSAndPolyResistors(polyLayer: poly, bodyMarkerLayer: marker) }
    private func source() throws -> LayoutDocument {
        let child = try ResistorCellGenerator().generateCell(deviceKindID: "resistor", instanceName: "R",
            parameters: ["r": 1_000], tech: .sampleProcess())
        let a = UUID(), b = UUID(), c = UUID()
        let root = LayoutCell(name: "ROOT", instances: [
            .init(cellID: child.id, name: "R1", terminalNetIDs: ["neg": a, "pos": b]),
            .init(cellID: child.id, name: "R2", transform: .init(translation: .init(x: 5, y: 0)),
                terminalNetIDs: ["neg": b, "pos": c])], nets: [.init(id: a, name: "A"), .init(id: b, name: "B"), .init(id: c, name: "C")])
        return .init(name: "resistors", cells: [root, child], topCellID: root.id)
    }
    private func captured(_ document: LayoutDocument, limits: LayoutConductorCaptureLimits = .default) throws -> LayoutConductorSnapshot {
        try DeviceExtractor().captureConductors(document: document, tech: .sampleProcess(), limits: limits,
            electricalContext: context)
    }

    @Test func generatedRepeatedResistorsKeepActualTerminalPiecesAndMarkerProvenance() throws {
        let document = try source(), original = document
        let result = try captured(document)
        let raw = try LayoutConnectivityExtractor().captureElectricalConductors(document: document, tech: .sampleProcess(),
            electricalContext: .geometric)
        #expect(raw.shortComponentIndices.count == 2)
        #expect(result.shortComponentIndices.isEmpty && result.components.count == 4 && result.pins.count == 4)
        #expect(result.pins.allSatisfy { $0.componentIndices.count == 1 && !$0.footprintIndices.isEmpty })
        #expect(result.preparedShapeGeometry.count == 2 && result.preparedShapeGeometry.values.allSatisfy { $0.count == 2 })
        #expect(result.hierarchy.shapes.filter { $0.layer == marker }.count == 2)
        #expect(Set(result.preparedShapeGeometry.keys.map { index in
            result.hierarchy.occurrences.firstIndex { $0.shapeRange.contains(index) }!
        }) == [1, 2])
        let encoded = try JSONEncoder().encode(result.electricalContext)
        let decoded = try JSONDecoder().decode(LayoutElectricalContext.self, from: encoded)
        #expect(decoded == context)
        #expect(document == original)
        let drc = try LayoutDRCService().runChecked(document: document, tech: .sampleProcess(), electricalContext: context)
        #expect(!drc.violations.contains { $0.kind == .overlapShort })
        #expect(drc.sourceHierarchy == result.hierarchy)
    }

    @Test func missingTerminalGeometryRemainsDisconnectedAndRealMetalBypassStillShorts() throws {
        var document = try source()
        let childIndex = 1, contact = LayoutLayerID(name: "CONTACT", purpose: "cut")
        document.cells[childIndex].shapes.removeAll { $0.layer == contact }
        let disconnected = try captured(document)
        #expect(disconnected.shortComponentIndices.isEmpty)
        #expect(disconnected.pins.allSatisfy { $0.componentIndices.count == 1 })
        // Pins remain on their M1 pads, which must no longer contact either poly terminal.
        #expect(disconnected.pins.allSatisfy { pin in
            pin.componentIndices.allSatisfy { index in
                disconnected.components[index].footprintIndices.allSatisfy { disconnected.footprints[$0].layer != poly }
            }
        })
        document.cells[childIndex].shapes.removeAll { $0.layer == LayoutLayerID(name: "M1", purpose: "drawing") }
        let open = try captured(document)
        #expect(open.pins.allSatisfy { $0.componentIndices.isEmpty })
        #expect(open.opens.reduce(0) { $0 + $1.unconnectedPinIndices.count } == 4)
        document = try source()
        let child = document.cells[1], m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let left = child.pins.first { $0.name == "neg" }!, right = child.pins.first { $0.name == "pos" }!
        document.cells[1].shapes.append(.init(layer: m1, geometry: .polygon(.init(points: [
            .init(x: left.position.x, y: 0.1), .init(x: right.position.x, y: 0.1),
            .init(x: right.position.x, y: 0.3), .init(x: left.position.x, y: 0.3)]))))
        #expect(try captured(document).shortComponentIndices.count == 2)
    }

    @Test func malformedBodyAndMaterialRolesFailBeforePublication() throws {
        var document = try source()
        let markerIndex = try #require(document.cells[1].shapes.firstIndex { $0.layer == marker })
        document.cells[1].shapes[markerIndex].geometry = .rect(.init(origin: .init(x: 1, y: 0.1), size: .init(width: 0.1, height: 0.1)))
        #expect(throws: LayoutConductorCaptureError.unsupportedDevicePreparation) { try captured(document) }
        #expect(throws: LayoutConductorCaptureError.unsupportedDevicePreparation) {
            try DeviceExtractor().captureConductors(document: source(), tech: .sampleProcess(),
                electricalContext: .deviceAwareMOSAndPolyResistors(polyLayer: poly, bodyMarkerLayer: poly))
        }
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.contactProbes)) {
            try captured(source(), limits: .init(maximumContactProbes: 0))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LayoutElectricalContext.self, from: Data("\"deviceAwareMOSAndPolyResistors\"".utf8))
        }
    }

    @Test func liveProfileMatchesBatchAndInvalidBodyEditIsAtomic() throws {
        let document = try source()
        let session = try LiveConnectivitySession(document: document, tech: .sampleProcess(), electricalContext: context)
        #expect(session.currentAnalysis.sourceSnapshot?.electricalContext == context)
        #expect(session.currentSnapshot == (try captured(document)))
        let before = session.currentAnalysis
        let invalid = LayoutShape(layer: marker, geometry: .rect(.init(origin: .zero, size: .init(width: 1, height: 1))))
        #expect(throws: LayoutConductorCaptureError.unsupportedDevicePreparation) {
            try session.apply(.init(addedShapes: [invalid]))
        }
        #expect(session.currentAnalysis == before)
    }
}
