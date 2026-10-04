import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Live native conductor generation", .timeLimit(.minutes(1)))
struct LiveProductionConnectivityTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private func rect(_ x: Double, _ y: Double = 0, _ width: Double = 1, _ height: Double = 1) -> LayoutRect {
        .init(origin: .init(x: x, y: y), size: .init(width: width, height: height))
    }
    private func shape(_ x: Double, id: UUID = UUID(), net: UUID? = nil) -> LayoutShape {
        .init(id: id, layer: m1, netID: net, geometry: .rect(rect(x)))
    }
    private func document(_ cell: LayoutCell, children: [LayoutCell] = []) -> LayoutDocument {
        .init(name: "live-generation", cells: [cell] + children, topCellID: cell.id)
    }
    private func expectNative(_ session: LiveConnectivitySession, _ document: LayoutDocument,
                              tech: LayoutTechDatabase = .standard(), sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = try LayoutConnectivityExtractor().extract(document: document, tech: tech)
        #expect(session.currentAnalysis == reference, sourceLocation: sourceLocation)
        #expect(session.currentAnalysis.sourceSnapshot == reference.sourceSnapshot, sourceLocation: sourceLocation)
    }

    @Test func everyCutIsReplacedAtomicallyWithCurrentSourceOrdinals() throws {
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut"), net = UUID()
        var tech = LayoutTechDatabase.standard()
        let cuts = [rect(0), rect(10)]
        tech.vias = [.init(id: "VIA1", cutLayer: cut, topLayer: m2, bottomLayer: m1,
            cutSize: .init(width: 1, height: 1), enclosure: .init(top: 0, bottom: 0), cutSpacing: 9,
            layerGeometries: [cut, m1, m2].map { .init(layer: $0, rects: cuts) })]
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .zero, netID: net)
        let cell = LayoutCell(name: "ARRAY", vias: [via])
        var source = document(cell)
        let session = try LiveConnectivitySession(document: source, tech: tech)
        #expect(session.currentAnalysis.nets.count == 2)
        #expect(session.currentAnalysis.opens.first?.islands.count == 2)
        let bridge = LayoutShape(layer: m1, netID: net, geometry: .rect(rect(0, 0, 11)))
        let joined = try session.apply(.init(addedShapes: [bridge]))
        source.cells[0].shapes = [bridge]
        #expect(joined.capturedFootprintCount == 1)
        #expect(joined.materializedFootprintCount == 7)
        #expect(joined.analysis.nets.count == 1)
        try expectNative(session, source, tech: tech)
        var moved = via; moved.position = .init(x: 30, y: 0)
        let replaced = try session.apply(.init(updatedVias: [moved]))
        source.cells[0].vias = [moved]
        #expect(replaced.capturedFootprintCount == 6)
        #expect(replaced.analysis.nets.count == 3)
        try expectNative(session, source, tech: tech)
        _ = try session.apply(.init(removedShapeIDs: [bridge.id], removedViaIDs: [via.id]))
        source.cells[0].shapes = []; source.cells[0].vias = []
        try expectNative(session, source, tech: tech)
    }

    @Test func repeatedChildNetAndPinIdentitySurvivesRootSourceInsertion() throws {
        let localNet = UUID(), childShape = shape(0, net: UUID())
        var labeled = childShape; labeled.netID = localNet
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: localNet)
        let child = LayoutCell(name: "CHILD", shapes: [labeled], pins: [pin])
        let top = LayoutCell(name: "TOP", instances: [
            .init(cellID: child.id, name: "left"),
            .init(cellID: child.id, name: "right", transform: .init(translation: .init(x: 10, y: 0)))])
        var source = document(top, children: [child])
        let session = try LiveConnectivitySession(document: source, tech: .standard())
        let original = session.currentAnalysis
        let root = shape(-10, id: childShape.id, net: localNet)
        _ = try session.apply(.init(addedShapes: [root])); source.cells[0].shapes = [root]
        try expectNative(session, source)
        let snapshot = try #require(session.currentAnalysis.sourceSnapshot)
        #expect(Set(session.currentAnalysis.nets.flatMap(\.declaredNets)).count == 3)
        #expect(snapshot.hierarchy.shapes.map(\.id) == [childShape.id, childShape.id, childShape.id])
        #expect(snapshot.hierarchy.pins.map(\.id) == [pin.id, pin.id])
        #expect(snapshot.pins.map(\.occurrenceIndex) == [1, 2])
        #expect(snapshot.pins.map(\.sourcePinIndex) == [0, 1])
        _ = try session.apply(.init(removedShapeIDs: [root.id])); source.cells[0].shapes = []
        try expectNative(session, source)
        #expect(session.currentAnalysis == original)
    }

    @Test func pinIncidenceDoesNotSpreadToAnUntouchedBandAfterSplit() throws {
        let net = UUID(), first = shape(0), second = shape(1)
        let pin = LayoutPin(name: "P", position: .init(x: 0.25, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: net)
        var source = document(LayoutCell(name: "PIN", shapes: [first, second], pins: [pin]))
        let session = try LiveConnectivitySession(document: source, tech: .standard())
        #expect(session.currentAnalysis.nets.count == 1)
        var moved = second; moved.geometry = .rect(rect(10))
        _ = try session.apply(.init(updatedShapes: [moved])); source.cells[0].shapes[1] = moved
        try expectNative(session, source)
        #expect(session.currentAnalysis.opens.isEmpty)
        let floating = try #require(session.currentAnalysis.nets.first { $0.shapeIDs == [second.id] })
        #expect(floating.declaredNets.isEmpty)
        let snapshot = try #require(session.currentAnalysis.sourceSnapshot)
        #expect(snapshot.pins[0].footprintIndices == [0])
        _ = try session.apply(.init(removedShapeIDs: [first.id])); source.cells[0].shapes.removeFirst()
        try expectNative(session, source)
        #expect(session.currentAnalysis.opens.first?.unconnectedPinIndices == [0])
        #expect(session.currentAnalysis.opens.first?.islands.isEmpty == true)
    }

    @Test func fullProfileScaleControlsPartialCaptureAndLastPathRemoval() throws {
        let half = LayoutShape(layer: m1, geometry: .rect(rect(0.0005, 0, 0.001, 0.001)))
        let path = LayoutShape(layer: m1, geometry: .path(.init(points: [.init(x: 10, y: 0), .init(x: 11, y: 0)], width: 0.002, endCap: .truncate)))
        var source = document(LayoutCell(name: "GRID", shapes: [half, path]))
        let session = try LiveConnectivitySession(document: source, tech: .standard())
        var moved = half; moved.geometry = .rect(rect(0.0015, 0, 0.001, 0.001))
        _ = try session.apply(.init(updatedShapes: [moved])); source.cells[0].shapes[0] = moved
        try expectNative(session, source)
        let before = session.currentAnalysis
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(half.id)) {
            try session.apply(.init(removedShapeIDs: [path.id]))
        }
        #expect(session.currentAnalysis == before)
        moved.geometry = .rect(rect(0.002, 0, 0.002, 0.002))
        _ = try session.apply(.init(updatedShapes: [moved])); source.cells[0].shapes[0] = moved
        _ = try session.apply(.init(removedShapeIDs: [path.id])); source.cells[0].shapes.removeLast()
        try expectNative(session, source)
        #expect(session.currentAnalysis.sourceSnapshot?.coordinateUnits == source.units)
    }

    @Test func geometryAndTechnologyFailuresRetainTheCompleteGeneration() throws {
        let wire = shape(0), source = document(LayoutCell(name: "FAIL", shapes: [shape(10)]))
        let session = try LiveConnectivitySession(document: source, tech: .standard())
        let before = session.currentAnalysis
        let invalidVia = LayoutVia(viaDefinitionID: "missing", position: .zero)
        #expect(throws: LayoutConductorCaptureError.missingViaDefinition("missing")) {
            try session.apply(.init(addedVias: [invalidVia]))
        }
        var offGrid = wire; offGrid.geometry = .rect(rect(0.00025))
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(wire.id)) {
            try session.apply(.init(addedShapes: [offGrid]))
        }
        #expect(session.currentAnalysis == before)
        _ = try session.apply(.init(addedShapes: [wire]))
        var final = source; final.cells[0].shapes.append(wire)
        try expectNative(session, final)
    }

    @Test func footprintProbeAndSpatialBudgetsFailBeforePublication() throws {
        let source = document(LayoutCell(name: "BUDGET", shapes: [shape(0)]))
        let limited = try LiveConnectivitySession(document: source, tech: .standard(), limits: .init(maximumFootprints: 1))
        let before = limited.currentAnalysis
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.footprints)) {
            try limited.apply(.init(addedShapes: [shape(10)]))
        }
        #expect(limited.currentAnalysis == before)
        let spatial = try LiveConnectivitySession(document: source, tech: .standard(), limits: .init(maximumContactProbes: 1000))
        let spatialBefore = spatial.currentAnalysis
        let huge = LayoutShape(layer: m1, geometry: .rect(rect(0, 0, 1_000_000, 1_000_000)))
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.spatialIndexEntries)) {
            try spatial.apply(.init(addedShapes: [huge]))
        }
        #expect(spatial.currentAnalysis == spatialBefore)
        let dense = document(LayoutCell(name: "DENSE", shapes: (0..<30).map { _ in shape(0) }))
        let probe = try LiveConnectivitySession(document: dense, tech: .standard(), limits: .init(maximumContactProbes: 1000))
        let probeBefore = probe.currentAnalysis
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.contactProbes)) {
            try probe.apply(.init(addedShapes: (0..<30).map { _ in shape(0) }))
        }
        #expect(probe.currentAnalysis == probeBefore)
    }

    @Test func cancellationRetainsTheCompleteGeneration() async throws {
        let source = document(LayoutCell(name: "CANCEL", shapes: [shape(0)])), extra = shape(10)
        let result = try await Task {
            let session = try LiveConnectivitySession(document: source, tech: .standard())
            let before = session.currentAnalysis
            withUnsafeCurrentTask { task in if let task { task.cancel() } }
            do {
                _ = try session.apply(.init(addedShapes: [extra]))
                return false
            } catch let error as LayoutConductorCaptureError {
                return error == .cancelled && session.currentAnalysis == before
            }
        }.value
        #expect(result)
    }

    @Test func localWorkAndFullMaterializationAreMeasuredSeparately() throws {
        let wires = (0..<200).map { shape(Double($0 * 10)) }
        var source = document(LayoutCell(name: "LOCAL", shapes: wires))
        let session = try LiveConnectivitySession(document: source, tech: .standard())
        var moved = wires[0]; moved.geometry = .rect(rect(0.1))
        let update = try session.apply(.init(updatedShapes: [moved])); source.cells[0].shapes[0] = moved
        try expectNative(session, source)
        #expect(update.capturedFootprintCount == 1)
        #expect(update.recomputedElementCount == 1)
        #expect(update.recomputedComponentCount == 1)
        #expect(update.contactProbeCount < 200)
        #expect(update.spatialCellVisitCount < 200)
        #expect(update.materializedFootprintCount == 200)
        #expect(update.storedSpatialEntryCount <= LayoutConductorCaptureLimits.default.maximumContactProbes)
        print("Live locality: captured=\(update.capturedFootprintCount) probes=\(update.contactProbeCount) cells=\(update.spatialCellVisitCount) affected=\(update.recomputedElementCount) materialized=\(update.materializedFootprintCount) duration=\(update.duration)")
    }
}
