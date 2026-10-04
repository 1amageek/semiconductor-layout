import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutAutoGen
import LayoutVerify

@Suite("Scoped native production consumers", .timeLimit(.minutes(1)))
struct ProductionConsumerScopedTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private func rect(_ x: Double, width: Double = 1) -> LayoutGeometry {
        .rect(.init(origin: .init(x: x, y: 0), size: .init(width: width, height: 1)))
    }
    private func document(_ top: LayoutCell, _ children: [LayoutCell] = []) -> LayoutDocument {
        .init(name: "consumer-proof", cells: [top] + children, topCellID: top.id)
    }

    @Test func rectangleEndpointsUseAdmittedSourceOperandsBeforeCancellation() throws {
        let shape = LayoutShape(layer: m1, geometry: .rect(.init(origin: .init(x: 0, y: -1.6), size: .init(width: 0.2, height: 1.7))))
        let source = document(.init(name: "RECT", shapes: [shape]))
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: source, tech: .standard(), conductiveLayers: [m1])
        let footprint = try #require(snapshot.footprints.first)
        let scale = snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        #expect(Double(footprint.band.minY) / scale == -1.6)
        #expect(Double(footprint.band.maxY) / scale == 0.1)
        #expect(snapshot.hierarchy.shapes.first?.geometry == shape.geometry)
        let overflow = LayoutShape(layer: m1, geometry: .rect(.init(origin: .init(x: Double(Int32.max) / scale, y: 0), size: .init(width: 1, height: 1))))
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(overflow.id)) {
            try LayoutConnectivityExtractor().captureConductors(document: document(.init(name: "OVERFLOW", shapes: [overflow])), tech: .standard(), conductiveLayers: [m1])
        }
    }

    @Test func sampleContactAlternativesUseActualSeparateMaterials() throws {
        let active = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let poly = LayoutLayerID(name: "POLY", purpose: "drawing")
        let cut = LayoutLayerID(name: "CONTACT", purpose: "cut")
        let tech = LayoutTechDatabase.sampleProcess()
        let shapes = [LayoutShape(layer: active, geometry: rect(0)), LayoutShape(layer: poly, geometry: rect(10)),
            LayoutShape(layer: m1, geometry: rect(0)), LayoutShape(layer: m1, geometry: rect(10)),
            LayoutShape(layer: cut, geometry: rect(0)), LayoutShape(layer: cut, geometry: rect(10))]
        let source = document(.init(name: "ALTERNATIVES", shapes: shapes))
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: source, tech: tech,
            conductiveLayers: [active, poly, m1])
        #expect(snapshot.components.count == 2)
        #expect(snapshot.components.map(\.footprintIndices.count) == [3, 3])
        for component in snapshot.components {
            let layers = Set(component.footprintIndices.map { snapshot.footprints[$0].layer })
            #expect(!(layers.contains(active) && layers.contains(poly)))
        }
        var ambiguous = tech
        ambiguous.contacts[1].topLayer = LayoutLayerID(name: "M2", purpose: "drawing")
        #expect(throws: LayoutConductorCaptureError.ambiguousLayerRole(cut)) {
            try LayoutConnectivityExtractor().captureConductors(document: source, tech: ambiguous,
                conductiveLayers: [active, poly, m1])
        }
    }

    @Test func reversedViaLandingSharingOneCutIsRejected() throws {
        var tech = LayoutTechDatabase.standard()
        let via = try #require(tech.vias.first)
        var reversed = via
        reversed.id = "reversed-stack"
        reversed.topLayer = via.bottomLayer; reversed.bottomLayer = via.topLayer
        tech.vias.append(reversed)
        #expect(throws: LayoutConductorCaptureError.ambiguousLayerRole(via.cutLayer)) {
            try LayoutConnectivityExtractor().captureConductors(document: document(.init(name: "EMPTY")), tech: tech,
                conductiveLayers: [via.bottomLayer, via.topLayer])
        }
    }

    @Test func devicePortsDoNotJoinIndependentCuts() throws {
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut"), m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        var tech = LayoutTechDatabase.standard()
        let cuts = [LayoutRect(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1)),
                    LayoutRect(origin: .init(x: 10, y: 0), size: .init(width: 1, height: 1))]
        tech.vias = [.init(id: "VIA1", cutLayer: cut, topLayer: m2, bottomLayer: m1,
            cutSize: .init(width: 1, height: 1), enclosure: .init(top: 0, bottom: 0), cutSpacing: 9,
            layerGeometries: [cut, m1, m2].map { .init(layer: $0, rects: cuts) })]
        let pins = [LayoutPin(name: "left", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1),
                    LayoutPin(name: "right", position: .init(x: 10.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1)]
        let source = document(.init(name: "CUT_PORTS", vias: [.init(viaDefinitionID: "VIA1", position: .zero)], pins: pins))
        let device = try DeviceExtractor().extract(document: source, tech: tech)
        #expect(device.issues.isEmpty)
        #expect(device.netlist.ports["left"] == ComparisonNetID("pin:left"))
        #expect(device.netlist.ports["right"] == ComparisonNetID("pin:right"))
        #expect(device.netlist.ports["left"] != device.netlist.ports["right"])
    }

    @Test func scopedDRCReportRetainsRepeatedSourcePinsAndIsolatedOpens() throws {
        let net = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: net)
        let child = LayoutCell(name: "CHILD", shapes: [LayoutShape(layer: m1, netID: net, geometry: rect(0)),
            LayoutShape(layer: m1, netID: net, geometry: rect(2))], pins: [pin])
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: child.id, name: "left"),
            .init(cellID: child.id, name: "right", transform: .init(translation: .init(x: 10, y: 0)))])
        let result = try LayoutDRCService().runChecked(document: document(top, [child]), tech: .standard())
        let opens = result.violations.filter { $0.kind == .disconnectedOpen }
        #expect(opens.count == 2)
        #expect(Set(opens.flatMap(\.netReferences).map(\.occurrenceIndex)) == [1, 2])
        #expect(Set(opens.flatMap(\.sourcePinIndices)) == [0, 1])
        #expect(opens.flatMap(\.pinIDs) == [pin.id, pin.id])
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LayoutDRCResult.self, from: encoded)
        #expect(decoded == result)
        #expect(decoded.sourceHierarchy?.pins.map(\.id) == [pin.id, pin.id])
        #expect(decoded.sourceHierarchy?.occurrences[1].path != decoded.sourceHierarchy?.occurrences[2].path)
        var withoutOwner = result; withoutOwner.sourceHierarchy = nil
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LayoutDRCResult.self, from: JSONEncoder().encode(withoutOwner))
        }
    }

    @Test func incrementalElectricalFactsUseScopedNativeLiveGeneration() throws {
        let net = UUID(), sourceID = UUID()
        let child = LayoutCell(name: "CHILD", shapes: [LayoutShape(id: sourceID, layer: m1, netID: net, geometry: rect(0))])
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: child.id, name: "left"),
            .init(cellID: child.id, name: "right", transform: .init(translation: .init(x: 2, y: 0)))])
        var source = document(top, [child])
        let session = try IncrementalDRCSession(document: source, tech: .standard())
        let before = session.currentResult
        let bridge = LayoutShape(id: sourceID, layer: m1, geometry: rect(0, width: 3))
        let update = try session.apply(.init(addedShapes: [bridge])); source.cells[0].shapes = [bridge]
        let short = try #require(update.result.violations.first { $0.kind == .overlapShort })
        #expect(short.netReferences.count == 2)
        #expect(Set(short.netReferences.map(\.occurrenceIndex)) == [1, 2])
        let batch = try LayoutDRCService().runChecked(document: source, tech: .standard())
        #expect(Set(update.result.violations) == Set(batch.violations))
        #expect(update.result.sourceHierarchy == batch.sourceHierarchy)
        let prior = session.currentResult
        var invalid = bridge; invalid.geometry = rect(0.00025)
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(sourceID)) {
            try session.apply(.init(updatedShapes: [invalid]))
        }
        #expect(session.currentResult == prior)
        _ = try session.apply(.init(removedShapeIDs: [bridge.id]))
        #expect(session.currentResult == before)
    }

    @Test func centeredPinsUseSourceLatticeAndRejectOffGridInput() throws {
        let shape = LayoutShape(layer: m1, geometry: rect(0, width: 0.34))
        let pin = LayoutPin(name: "P", position: .init(x: 0.17, y: 0.5), size: .init(width: 0.34, height: 1), layer: m1)
        let source = document(.init(name: "CENTERED", shapes: [shape], pins: [pin]))
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: source, tech: .standard(), conductiveLayers: [m1])
        #expect(snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer == 2_000)
        #expect(snapshot.pins[0].bands[0].minX == 0 && snapshot.pins[0].bands[0].maxX == 680)
        #expect(snapshot.pins[0].footprintIndices == [0])
        #expect(snapshot.hierarchy.pins[0] == pin)
        var invalid = source; invalid.cells[0].pins[0].position.x = 0.00025
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(pin.id)) {
            try LayoutConnectivityExtractor().captureConductors(document: invalid, tech: .standard(), conductiveLayers: [m1])
        }
    }

    @Test func repeatedDevicePinsKeepIndependentComparisonNets() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let child = try MOSFETCellGenerator().generateCell(deviceKindID: "nmos", instanceName: "M1", parameters: ["w": 2.0, "l": 0.18], tech: tech)
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: child.id, name: "left"),
            .init(cellID: child.id, name: "right", transform: .init(translation: .init(x: 10, y: 0)))])
        let result = try DeviceExtractor().extract(document: document(top, [child]), tech: tech)
        #expect(result.issues.isEmpty)
        #expect(result.netlist.devices.count == 2 && result.netlist.ports.isEmpty)
        let gates = Set(result.netlist.devices.compactMap { $0.terminals[.gate] })
        #expect(gates.count == 2)
        for device in result.netlist.devices {
            #expect(device.terminals[.source] != device.terminals[.drain])
            #expect(abs(device.parameters.width - 2) < 1e-9 && abs(device.parameters.length - 0.18) < 1e-9)
        }
    }

    @Test func pointAuthorizationKeepsContinuousCoordinatesWithoutEdgeClamping() throws {
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: document(.init(name: "EDGE",
            shapes: [LayoutShape(layer: m1, geometry: rect(0))])), tech: .standard(), conductiveLayers: [m1])
        #expect(try snapshot.componentIndices(containing: .init(x: 1, y: 0.5), on: m1) == [0])
        #expect(try snapshot.componentIndices(containing: .init(x: 0.5, y: 0.5), on: m1) == [0])
        #expect(try snapshot.componentIndices(containing: .init(x: Double(1).nextUp, y: 0.5), on: m1).isEmpty)
        #expect(try snapshot.componentIndices(containing: .init(x: 0.5000000001, y: 0.5), on: m1) == [0])
        #expect(throws: LayoutConductorCaptureError.invalidQueryPoint) {
            try snapshot.componentIndices(containing: .init(x: .nan, y: 0.5), on: m1)
        }
        #expect(try snapshot.componentIndices(containing: .init(x: 1.001, y: 0.5), on: m1).isEmpty)
    }

    @Test func deviceContextSharesPreparedSlabsWithLiveAndDRC() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let cell = try MOSFETCellGenerator().generateCell(deviceKindID: "nmos", instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18], tech: tech)
        var source = document(cell)
        let snapshot = try DeviceExtractor().captureConductors(document: source, tech: tech)
        #expect(snapshot.electricalContext == .deviceAwareMOS)
        #expect(snapshot.hierarchy.shapes == cell.shapes)
        let sourceIndex = try #require(cell.pins.firstIndex { $0.role == .source })
        let drainIndex = try #require(cell.pins.firstIndex { $0.role == .drain })
        let sourcePin = try #require(snapshot.pins.first { $0.sourcePinIndex == sourceIndex })
        let drainPin = try #require(snapshot.pins.first { $0.sourcePinIndex == drainIndex })
        #expect(sourcePin.componentIndices.count == 1 && drainPin.componentIndices.count == 1)
        #expect(sourcePin.componentIndices != drainPin.componentIndices)
        let batch = try LayoutConnectivityExtractor().extract(document: source, tech: tech, electricalContext: .deviceAwareMOS)
        #expect(batch.sourceSnapshot == snapshot)
        let live = try LiveConnectivitySession(document: source, tech: tech, electricalContext: .deviceAwareMOS)
        #expect(live.currentAnalysis == batch)
        let gate = try #require(cell.shapes.first { $0.layer.name == "POLY" })
        let update = try live.apply(.init(removedShapeIDs: [gate.id]))
        source.cells[0].shapes.removeAll { $0.id == gate.id }
        let after = try LayoutConnectivityExtractor().extract(document: source, tech: tech, electricalContext: .deviceAwareMOS)
        #expect(update.analysis == after)
        #expect(update.capturedFootprintCount > 0)
        #expect(update.materializedFootprintCount == after.sourceSnapshot?.footprints.count)
        let drc = try LayoutDRCService().runChecked(document: source, tech: tech, electricalContext: .deviceAwareMOS)
        #expect(drc.electricalContext == .deviceAwareMOS && drc.sourceHierarchy == after.sourceSnapshot?.hierarchy)
        #expect(try JSONDecoder().decode(LayoutDRCResult.self, from: JSONEncoder().encode(drc)) == drc)
        let prior = live.currentAnalysis
        var invalid = source.cells[0].shapes[0]; invalid.geometry = rect(0.00025)
        #expect(throws: LayoutConductorCaptureError.self) { try live.apply(.init(updatedShapes: [invalid])) }
        #expect(live.currentAnalysis == prior)
    }

    @Test func minimumCutsCompareScopedSourceNets() throws {
        let net = UUID(), m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let lower = LayoutCell(name: "LOWER", shapes: [LayoutShape(layer: m1, netID: net, geometry: rect(0))])
        let upper = LayoutCell(name: "UPPER", shapes: [LayoutShape(layer: m2, netID: net, geometry: rect(0))])
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: lower.id, name: "lower"), .init(cellID: upper.id, name: "upper")])
        var tech = LayoutTechDatabase.standard()
        tech.minimumCutRules = [.init(id: "scoped", cutLayer: .init(name: "VIA1", purpose: "cut"), bottomLayer: m1, topLayer: m2, minimumCount: 1)]
        let separate = try LayoutDRCService().runChecked(document: document(top, [lower, upper]), tech: tech)
        #expect(separate.violations.filter { $0.kind == .minimumCut }.isEmpty)
        let combined = LayoutCell(name: "COMBINED", shapes: lower.shapes + upper.shapes)
        let joined = try LayoutDRCService().runChecked(document: document(combined), tech: tech)
        let violation = try #require(joined.violations.first { $0.kind == .minimumCut })
        #expect(violation.measured == 0 && violation.required == 1)
        #expect(violation.netReferences == [.init(occurrenceIndex: 0, netID: net)])
    }

    @Test func minimumCutDoesNotCountFeaturesInsideAnOverlapHole() throws {
        let net = UUID(), m2 = LayoutLayerID(name: "M2", purpose: "drawing"), cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let bottom = LayoutShape(layer: m1, netID: net, geometry: .polygon(.init(points: [
            .init(x: 0, y: 0), .init(x: 3, y: 0), .init(x: 3, y: 3), .init(x: 2, y: 3),
            .init(x: 2, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 3), .init(x: 0, y: 3)])))
        let top = LayoutShape(layer: m2, netID: net, geometry: .rect(.init(origin: .zero, size: .init(width: 3, height: 3))))
        let disconnectedCut = LayoutShape(layer: cut, netID: net, geometry: .rect(.init(origin: .init(x: 1.25, y: 1.5), size: .init(width: 0.5, height: 0.5))))
        var tech = LayoutTechDatabase.standard()
        tech.minimumCutRules = [.init(id: "actual-area", cutLayer: cut, bottomLayer: m1, topLayer: m2, minimumCount: 1)]
        let result = try LayoutDRCService().runChecked(document: document(.init(name: "HOLE", shapes: [bottom, top, disconnectedCut])), tech: tech)
        let failure = try #require(result.violations.first { $0.kind == .minimumCut })
        #expect(failure.measured == 0 && failure.required == 1)
        #expect(!failure.shapeIDs.contains(disconnectedCut.id))
    }

    @Test func splitComparisonNameCannotCollideWithADeclaredName() throws {
        let net = LayoutNet(name: "A"), other = LayoutNet(name: "A:split:1")
        let shapes = [LayoutShape(layer: m1, netID: net.id, geometry: rect(0)),
            LayoutShape(layer: m1, netID: net.id, geometry: rect(2)),
            LayoutShape(layer: m1, netID: other.id, geometry: rect(4))]
        let pins = [LayoutPin(name: "left", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1),
            LayoutPin(name: "middle", position: .init(x: 2.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1),
            LayoutPin(name: "right", position: .init(x: 4.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1)]
        let result = try DeviceExtractor().extract(document: document(.init(name: "COLLISION", shapes: shapes, pins: pins, nets: [net, other])), tech: .standard())
        #expect(result.issues.contains { $0.kind == .openNet })
        #expect(Set([result.netlist.ports["left"], result.netlist.ports["middle"], result.netlist.ports["right"]].compactMap { $0 }).count == 3)
    }

}
