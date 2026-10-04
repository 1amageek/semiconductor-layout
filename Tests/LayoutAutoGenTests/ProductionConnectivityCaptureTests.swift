import Foundation
import Testing
import LayoutCore
import LayoutTech
@testable import LayoutVerify

@Suite("Production captured connectivity", .timeLimit(.minutes(1)))
struct ProductionConnectivityCaptureTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let cut = LayoutLayerID(name: "VIA1", purpose: "cut")

    private func rect(_ x: Double, _ y: Double = 0, _ width: Double = 1, _ height: Double = 1) -> LayoutRect {
        .init(origin: .init(x: x, y: y), size: .init(width: width, height: height))
    }
    private func document(_ cell: LayoutCell, children: [LayoutCell] = []) -> LayoutDocument {
        .init(name: "production", cells: [cell] + children, topCellID: cell.id)
    }
    private func arrayTech(bridged: Bool = false) -> LayoutTechDatabase {
        var tech = LayoutTechDatabase.standard()
        tech.vias[0].layerGeometries = [
            .init(layer: cut, rects: [rect(0), rect(10)]),
            .init(layer: m1, rects: bridged ? [rect(-1, -1, 13, 3)] : [rect(-1, -1, 3, 3), rect(9, -1, 3, 3)]),
            .init(layer: m2, rects: [rect(-1, -1, 3, 3), rect(9, -1, 3, 3)])
        ]
        return tech
    }

    @Test func batchKeepsIndependentCutsAndSharedHighlightOwner() throws {
        let net = UUID(), via = LayoutVia(viaDefinitionID: "VIA1", position: .zero, netID: UUID())
        var labeled = via; labeled.netID = net
        let result = try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "ARRAY", vias: [labeled])), tech: arrayTech())
        let root = try #require(result.rootNetReference(for: net))
        #expect(result.nets.count == 2 && result.opens.count == 1 && result.shorts.isEmpty)
        #expect(result.opens[0].netID == root && result.opens[0].islands.count == 2)
        #expect(result.nets.allSatisfy { $0.viaIDs == [via.id] && $0.memberKeys.count == 3 })
        #expect(Set(result.nets.flatMap(\.memberKeys)).count == 6)
    }

    @Test func disjointCutsCannotShortOppositeDeclaredNets() throws {
        let first = UUID(), second = UUID()
        let cell = LayoutCell(name: "NO_SHORT", shapes: [
            .init(layer: m1, netID: first, geometry: .rect(rect(0))),
            .init(layer: m2, netID: second, geometry: .rect(rect(10)))
        ], vias: [.init(viaDefinitionID: "VIA1", position: .zero)])
        let result = try LayoutConnectivityExtractor().extract(document: document(cell), tech: arrayTech())
        #expect(result.nets.count == 2 && result.shorts.isEmpty && result.opens.isEmpty)
        #expect(Set(result.nets.flatMap(\.declaredNets)) == [result.rootNetReference(for: first)!, result.rootNetReference(for: second)!])
    }

    @Test func actualMetalBridgeJoinsCutPieces() throws {
        let result = try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "BRIDGE", vias: [
            .init(viaDefinitionID: "VIA1", position: .zero)
        ])), tech: arrayTech(bridged: true))
        #expect(result.nets.count == 1 && result.nets[0].memberKeys.count == 5)
    }

    @Test func rawCutShapeUsesNativeLayerAdjacency() throws {
        let cell = LayoutCell(name: "RAW", shapes: [m1, cut, m2].map { .init(layer: $0, geometry: .rect(rect(0))) })
        let result = try LayoutConnectivityExtractor().extract(document: document(cell), tech: .standard())
        #expect(result.nets.count == 1 && result.nets[0].memberKeys.count == 3)
    }

    @Test func batchRejectsUnknownLayersAndNonGridGeometry() throws {
        let unknown = LayoutLayerID(name: "UNKNOWN", purpose: "drawing")
        let shape = LayoutShape(layer: unknown, geometry: .rect(rect(0)))
        #expect(throws: LayoutConductorCaptureError.unknownLayer(unknown)) {
            try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "UNKNOWN", shapes: [shape])), tech: .standard())
        }
        let offGrid = LayoutShape(layer: m1, geometry: .rect(rect(0.00025)))
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(offGrid.id)) {
            try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "GRID", shapes: [offGrid])), tech: .standard())
        }
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.technologyRecords)) {
            try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "LIMIT")), tech: .standard(),
                limits: .init(maximumTechnologyRecords: 2))
        }
    }

    @Test func reusedLocalUUIDRemainsIndependentUnlessExplicitlyBound() throws {
        let local = UUID(), parent = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: local)
        let child = LayoutCell(name: "CHILD", shapes: [.init(layer: m1, netID: local, geometry: .rect(rect(0)))], pins: [pin])
        var top = LayoutCell(name: "TOP", instances: [
            .init(cellID: child.id, name: "a"),
            .init(cellID: child.id, name: "b", transform: .init(translation: .init(x: 10, y: 0)))
        ])
        let extractor = LayoutConnectivityExtractor()
        let isolated = try extractor.extract(document: document(top, children: [child]), tech: .standard())
        let refs = isolated.nets.flatMap(\.declaredNets)
        #expect(refs.count == 2 && Set(refs).count == 2 && refs.allSatisfy { $0.netID == local })
        #expect(isolated.opens.isEmpty && isolated.shorts.isEmpty)
        top.instances[0].terminalNetIDs = ["P": parent]
        top.instances[1].terminalNetIDs = ["P": parent]
        let bound = try extractor.extract(document: document(top, children: [child]), tech: .standard())
        #expect(bound.opens.count == 1 && bound.opens[0].netID == bound.rootNetReference(for: parent))
        #expect(bound.opens[0].islands.count == 2 && bound.nets.allSatisfy { $0.declaredNets == [bound.opens[0].netID] })
    }

    @Test func isolatedPinsRetainOwnedSourceIdentityAndZeroIslandOpen() throws {
        let net = UUID(), pin = LayoutPin(name: "P", position: .init(x: 4, y: 4), size: .init(width: 0.2, height: 0.2), layer: m1, netID: UUID())
        var labeled = pin; labeled.netID = net
        let result = try LayoutConnectivityExtractor().extract(document: document(LayoutCell(name: "PIN", pins: [labeled])), tech: .standard())
        let open = try #require(result.opens.first), snapshot = try #require(result.sourceSnapshot)
        #expect(result.nets.isEmpty && open.netID == result.rootNetReference(for: net))
        #expect(open.islands.isEmpty && open.flylines.isEmpty && open.unconnectedPinIndices == [0])
        let fact = snapshot.pins[open.unconnectedPinIndices[0]]
        #expect(snapshot.hierarchy.pins[fact.sourcePinIndex].id == pin.id)
        #expect(fact.declaredNet == open.netID && fact.componentIndices.isEmpty)
    }

    @Test func fullPinAreaLabelsBothIslandsWithoutJoiningThem() throws {
        let net = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 2, y: 0.5), size: .init(width: 4, height: 0.8), layer: m1, netID: net)
        let cell = LayoutCell(name: "AREA", shapes: [0.0, 3.0].map { .init(layer: m1, geometry: .rect(rect($0))) }, pins: [pin])
        let result = try LayoutConnectivityExtractor().extract(document: document(cell), tech: .standard())
        #expect(result.nets.count == 2 && result.opens.count == 1 && result.shorts.isEmpty)
        #expect(result.nets.allSatisfy { $0.declaredNets == [result.opens[0].netID] })
    }

    @Test func publicContactQuerySharesNativeEdgeAndCornerSemantics() throws {
        let extractor = LayoutConnectivityExtractor(), tech = LayoutTechDatabase.standard()
        func capture(_ x: Double, _ y: Double = 0, layer: LayoutLayerID? = nil) throws -> LayoutConductorSnapshot {
            try extractor.captureConductors(document: document(LayoutCell(name: "ONE", shapes: [
                .init(layer: layer ?? m1, geometry: .rect(rect(x, y)))
            ])), tech: tech, conductiveLayers: [m1, m2])
        }
        let origin = try capture(0), edge = try capture(1), corner = try capture(1, 1), cutEdge = try capture(1, layer: cut)
        #expect(try origin.hasElectricalContact(footprintAt: 0, with: edge, footprintAt: 0))
        #expect(try !origin.hasElectricalContact(footprintAt: 0, with: corner, footprintAt: 0))
        #expect(try !origin.hasElectricalContact(footprintAt: 0, with: cutEdge, footprintAt: 0))
        #expect(throws: LayoutConductorCaptureError.invalidFootprintIndex(-1)) {
            try origin.hasElectricalContact(footprintAt: -1, with: edge, footprintAt: 0)
        }
    }

    @Test func contactQueryRejectsTechnologyAndNonIntegralScaleMixing() throws {
        let extractor = LayoutConnectivityExtractor(), cell = LayoutCell(name: "ONE", shapes: [.init(layer: m1, geometry: .rect(rect(0)))])
        let first = try extractor.captureConductors(document: document(cell), tech: .standard(), conductiveLayers: [m1, m2])
        var tech = LayoutTechDatabase.standard(); tech.vias[0].cutSize.width *= 2
        let changed = try extractor.captureConductors(document: document(cell), tech: tech, conductiveLayers: [m1, m2])
        #expect(throws: LayoutConductorCaptureError.incompatibleContactTopology) {
            try first.hasElectricalContact(footprintAt: 0, with: changed, footprintAt: 0)
        }
        var differentUnits = document(cell)
        differentUnits.units = .init(scale: try .init(databaseUnitsPerMicrometer: 1500))
        let fractional = try extractor.captureConductors(document: differentUnits, tech: .standard(), conductiveLayers: [m1, m2])
        #expect(throws: LayoutConductorCaptureError.incompatibleContactUnits) {
            try first.hasElectricalContact(footprintAt: 0, with: fractional, footprintAt: 0)
        }
        differentUnits.units = .init(scale: try .init(databaseUnitsPerMicrometer: 2000))
        let refined = try extractor.captureConductors(document: differentUnits, tech: .standard(), conductiveLayers: [m1, m2])
        #expect(try first.hasElectricalContact(footprintAt: 0, with: refined, footprintAt: 0))
        let deceptiveCell = LayoutCell(name: "THIRD", shapes: [.init(layer: m1, geometry: .rect(rect(0, 0, 0.003, 0.003)))])
        var deceptiveUnits = document(deceptiveCell)
        deceptiveUnits.units = .init(scale: try .init(databaseUnitsPerMicrometer: 1000 / 3))
        let deceptive = try extractor.captureConductors(document: deceptiveUnits, tech: .standard(), conductiveLayers: [m1, m2])
        #expect(throws: LayoutConductorCaptureError.incompatibleContactUnits) {
            try first.hasElectricalContact(footprintAt: 0, with: deceptive, footprintAt: 0)
        }
    }

    @Test func isolatedPinPlannerReportsSourcePinInsteadOfConnectedNet() throws {
        let net = UUID(), pin = LayoutPin(name: "P", position: .zero, size: .init(width: 0.2, height: 0.2), layer: m1, netID: UUID())
        var labeled = pin; labeled.netID = net
        let cell = LayoutCell(name: "PLAN_PIN", pins: [labeled])
        #expect(throws: HeadlessFinishNetPlannerError.unconnectedPinOpen(netID: net, pinIDs: [pin.id])) {
            try HeadlessFinishNetPlanner().plan(document: document(cell), tech: .standard(), cellID: cell.id,
                netID: net, layer: m1, width: nil, shapeIDSeed: "pin")
        }
    }

    @Test func unmigratedProductionConsumersFailExplicitly() throws {
        let doc = document(LayoutCell(name: "EMPTY")), tech = LayoutTechDatabase.standard()
        #expect(throws: LayoutConnectivityExtractionError.consumerMigrationIncomplete) { try LiveConnectivitySession(document: doc, tech: tech) }
        #expect(throws: LayoutConnectivityExtractionError.consumerMigrationIncomplete) { try DeviceExtractor().extract(document: doc, tech: tech) }
        #expect(throws: LayoutConnectivityExtractionError.consumerMigrationIncomplete) { try LayoutDRCService().runChecked(document: doc, tech: tech) }
        #expect(throws: LayoutConnectivityExtractionError.consumerMigrationIncomplete) { try IncrementalDRCSession(document: doc, tech: tech) }
        #expect(LayoutDRCService().run(document: doc, tech: tech).diagnostics.contains { $0.severity == .error })
    }
}
