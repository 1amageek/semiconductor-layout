import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify
import MaskGeometry

@Suite("Native bounded conductor contacts", .timeLimit(.minutes(1)))
struct ConductorCaptureTests {
    private var m1: LayoutLayerID { .init(name: "M1", purpose: "drawing") }
    private var m2: LayoutLayerID { .init(name: "M2", purpose: "drawing") }
    private var cut: LayoutLayerID { .init(name: "VIA1", purpose: "cut") }
    private var layers: Set<LayoutLayerID> { [m1, m2] }
    private func rect(_ x: Double, _ y: Double, _ width: Double = 1, _ height: Double = 1) -> LayoutRect {
        .init(origin: .init(x: x, y: y), size: .init(width: width, height: height))
    }
    private func shape(_ x: Double, layer: LayoutLayerID? = nil, net: UUID? = nil) -> LayoutShape {
        .init(layer: layer ?? m1, netID: net, geometry: .rect(rect(x, 0)))
    }
    private func document(_ cell: LayoutCell, children: [LayoutCell] = []) -> LayoutDocument {
        .init(name: "contact", cells: [cell] + children, topCellID: cell.id)
    }
    private func capture(_ cell: LayoutCell, tech: LayoutTechDatabase = .standard(),
                         limits: LayoutConductorCaptureLimits = .default) throws -> LayoutConductorSnapshot {
        try LayoutConnectivityExtractor().captureConductors(document: document(cell), tech: tech,
                                                           conductiveLayers: layers, limits: limits)
    }
    private func arrayTech(bridged: Bool = false) -> LayoutTechDatabase {
        var tech = LayoutTechDatabase.standard()
        tech.vias[0].layerGeometries = [
            .init(layer: cut, rects: [rect(0, 0), rect(10, 0)]),
            .init(layer: m1, rects: bridged ? [rect(-1, -1, 13, 3)] : [rect(-1, -1, 3, 3), rect(9, -1, 3, 3)]),
            .init(layer: m2, rects: [rect(-1, -1, 3, 3), rect(9, -1, 3, 3)])
        ]
        return tech
    }

    @Test func disjointCutsDoNotBecomeOneViaNode() throws {
        let net = UUID()
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .zero, netID: net)
        let result = try capture(LayoutCell(name: "ARRAY", vias: [via]), tech: arrayTech())
        #expect(result.footprints.count == 6 && result.components.count == 2)
        #expect(result.components.allSatisfy { $0.footprintIndices.count == 3 })
        #expect(result.contacts.count == 4)
        #expect(result.opens.count == 1 && result.opens[0].componentIndices == [0, 1])
        #expect(result.shortComponentIndices.isEmpty)
    }
    @Test func actualMetalBridgeConnectsIndependentCuts() throws {
        let result = try capture(LayoutCell(name: "BRIDGE", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)]), tech: arrayTech(bridged: true))
        #expect(result.footprints.count == 5 && result.components.count == 1)
        #expect(result.components[0].declaredNets.isEmpty)
    }
    @Test func overlappingViaMetalConnectsWithoutAnExternalWire() throws {
        var tech = LayoutTechDatabase.standard()
        let m3 = LayoutLayerID(name: "M3", purpose: "drawing"), v2 = LayoutLayerID(name: "VIA2", purpose: "cut")
        var metal = tech.layers[1]; metal.id = m3
        var cutLayer = tech.layers[2]; cutLayer.id = v2
        tech.layers += [metal, cutLayer]
        tech.vias.append(LayoutViaDefinition(id: "VIA2", cutLayer: v2, topLayer: m3, bottomLayer: m2,
            cutSize: .init(width: 0.05, height: 0.05), enclosure: .init(top: 0.01, bottom: 0.01), cutSpacing: 0.05))
        let cell = LayoutCell(name: "STACK", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero), LayoutVia(viaDefinitionID: "VIA2", position: .zero)])
        let result = try LayoutConnectivityExtractor().captureConductors(document: document(cell), tech: tech, conductiveLayers: [m1, m2, m3])
        #expect(result.footprints.count == 6 && result.components.count == 1)
        #expect(result.contacts.contains { result.footprints[$0.firstFootprint].layer == m2 && result.footprints[$0.secondFootprint].layer == m2 })
    }
    @Test func rawCutShapeUsesDeclaredAdjacency() throws {
        let cell = LayoutCell(name: "CUT", shapes: [shape(0), shape(0, layer: cut), shape(0, layer: m2)])
        let result = try capture(cell)
        #expect(result.components.count == 1 && result.footprints.filter(\.isCut).count == 1)
    }
    @Test func floatingMetalAndCrossLayerSeparationRemainVisible() throws {
        let result = try capture(LayoutCell(name: "FLOAT", shapes: [shape(0), shape(0, layer: m2), shape(4)]))
        #expect(result.components.count == 3 && result.footprints.count == 3)
        #expect(result.components.allSatisfy { $0.declaredNets.isEmpty })
    }
    @Test func sameLayerEdgesConductButCornersAndCrossLayerEdgesDoNot() throws {
        let corner = LayoutShape(layer: m1, geometry: .rect(rect(1, 1)))
        #expect(try capture(LayoutCell(name: "CORNER", shapes: [shape(0), corner])).components.count == 2)
        #expect(try capture(LayoutCell(name: "EDGE", shapes: [shape(0), shape(1)])).components.count == 1)
        #expect(try capture(LayoutCell(name: "CUT_EDGE", shapes: [shape(0), shape(1, layer: cut)])).components.count == 2)
    }
    @Test func concaveVoidCannotCreateFalsePinOrMetalContact() throws {
        let net = UUID()
        let polygon = LayoutShape(layer: m1, geometry: .polygon(LayoutPolygon(points: [
            .init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 1),
            .init(x: 1, y: 1), .init(x: 1, y: 4), .init(x: 0, y: 4)
        ])))
        let pin = LayoutPin(name: "VOID", position: .init(x: 2, y: 2), size: .init(width: 0.2, height: 0.2), layer: m1, netID: net)
        let result = try capture(LayoutCell(name: "VOID", shapes: [polygon], pins: [pin]))
        #expect(result.footprints.count == 2 && result.components.count == 1)
        #expect(result.pins[0].componentIndices.isEmpty)
        #expect(result.opens.count == 1 && result.opens[0].componentIndices.isEmpty && result.opens[0].unconnectedPinIndices == [0])
    }
    @Test func pinsLabelAllContactsWithoutBridgingIslands() throws {
        let pin = LayoutPin(name: "P", position: .init(x: 2, y: 0.5), size: .init(width: 4, height: 0.8), layer: m1, netID: UUID())
        let result = try capture(LayoutCell(name: "PINS", shapes: [shape(0), shape(3)], pins: [pin]))
        #expect(result.components.count == 2 && result.pins[0].componentIndices == [0, 1])
        #expect(result.opens.count == 1 && result.shortComponentIndices.isEmpty)
        #expect(result.components.allSatisfy { $0.pinIndices == [0] && $0.declaredNets.count == 1 })
    }
    @Test func unlabeledBridgeProducesARealShort() throws {
        let first = UUID(), second = UUID()
        let result = try capture(LayoutCell(name: "SHORT", shapes: [shape(0, net: first), shape(1), shape(2, net: second)]))
        #expect(result.components.count == 1 && result.shortComponentIndices == [0])
        #expect(Set(result.components[0].declaredNets.map(\.netID)) == [first, second])
    }
    @Test func repeatedLocalNetIDsStayScopedUntilExplicitParentBinding() throws {
        let local = UUID(), parent = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: local)
        let child = LayoutCell(name: "CHILD", shapes: [shape(0, net: local)], pins: [pin])
        var top = LayoutCell(name: "TOP", instances: [
            LayoutInstance(cellID: child.id, name: "a"),
            LayoutInstance(cellID: child.id, name: "b", transform: .init(translation: .init(x: 10, y: 0)))
        ])
        let extractor = LayoutConnectivityExtractor()
        let isolated = try extractor.captureConductors(document: document(top, children: [child]), tech: .standard(), conductiveLayers: layers)
        #expect(isolated.opens.isEmpty && isolated.components.count == 2)
        #expect(isolated.components.map { $0.declaredNets[0].occurrenceIndex } == [1, 2])
        top.instances[0].terminalNetIDs = ["P": parent]; top.instances[1].terminalNetIDs = ["P": parent]
        let bound = try extractor.captureConductors(document: document(top, children: [child]), tech: .standard(), conductiveLayers: layers)
        #expect(bound.opens.count == 1 && bound.opens[0].net.occurrenceIndex == 0 && bound.opens[0].net.netID == parent)
        #expect(bound.components.allSatisfy { $0.declaredNets.count == 1 })
    }
    @Test func nestedArrayOccurrenceAndWorldGeometryAreRetained() throws {
        let leaf = LayoutCell(name: "LEAF", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)])
        let instance = LayoutInstance(cellID: leaf.id, name: "array", transform: .init(rotation: .deg90, magnification: 2, mirrorX: true), repetition: .init(columns: 2, rows: 1, columnStep: .init(x: 30, y: 0), rowStep: .zero))
        let top = LayoutCell(name: "TOP", instances: [instance])
        let result = try LayoutConnectivityExtractor().captureConductors(document: document(top, children: [leaf]), tech: arrayTech(), conductiveLayers: layers)
        #expect(result.hierarchy.occurrences.count == 3 && result.footprints.count == 12 && result.components.count == 4)
        #expect(Set(result.footprints.map(\.occurrenceIndex)) == [1, 2])
        #expect(result.footprints[0].band.maxY - result.footprints[0].band.minY == 2000)
        #expect(result.hierarchy.vias[0].id == result.hierarchy.vias[1].id)
    }
    @Test func incompleteOrUnknownViaCannotInventGeometry() {
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .zero)
        var tech = arrayTech(); tech.vias[0].layerGeometries.removeLast()
        #expect(throws: LayoutConductorCaptureError.incompleteViaTopology(viaID: via.id, definitionID: "VIA1")) {
            try capture(LayoutCell(name: "PARTIAL", vias: [via]), tech: tech)
        }
        let unknown = LayoutVia(viaDefinitionID: "UNKNOWN", position: .zero)
        #expect(throws: LayoutConductorCaptureError.missingViaDefinition("UNKNOWN")) { try capture(LayoutCell(name: "UNKNOWN", vias: [unknown])) }
    }
    @Test func extraViaLayerWithoutAdjacencyIsRejected() {
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .zero)
        var tech = arrayTech(); tech.vias[0].layerGeometries.append(.init(layer: .init(name: "EXTRA", purpose: "drawing"), rects: [rect(0, 0)]))
        #expect(throws: LayoutConductorCaptureError.incompleteViaTopology(viaID: via.id, definitionID: "VIA1")) {
            try capture(LayoutCell(name: "EXTRA", vias: [via]), tech: tech)
        }
    }
    @Test func offGridCircularAndNonManhattanGeometryFailExplicitly() {
        let offGrid = shape(0.0004)
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(offGrid.id)) { try capture(LayoutCell(name: "GRID", shapes: [offGrid])) }
        let path = LayoutShape(layer: m1, geometry: .path(.init(points: [.zero, .init(x: 1, y: 0)], width: 0.1, endCap: .round)))
        #expect(throws: LayoutConductorCaptureError.unsupportedGeometry(path.id)) { try capture(LayoutCell(name: "PATH", shapes: [path])) }
        let diagonal = LayoutShape(layer: m1, geometry: .polygon(.init(points: [.zero, .init(x: 1, y: 0), .init(x: 0, y: 1)])))
        #expect(throws: LayoutConductorCaptureError.decompositionFailed(.unsupportedNonManhattanGeometry(polygonIndex: 0))) {
            try capture(LayoutCell(name: "DIAGONAL", shapes: [diagonal]))
        }
    }
    @Test func invalidExplicitViaRectangleCannotBeRepairedByTransform() {
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .zero, geometryTransforms: [.init(rotation: .deg90)])
        var tech = arrayTech()
        tech.vias[0].layerGeometries[0].rects[0].size.width = -1
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(via.id)) {
            try capture(LayoutCell(name: "INVALID", vias: [via]), tech: tech)
        }
    }
    @Test func emptyConductingCoverageIsNotEmptySuccess() {
        let empty = LayoutShape(layer: m1, geometry: .polygon(.init(points: [])))
        #expect(throws: LayoutConductorCaptureError.unsupportedGeometry(empty.id)) { try capture(LayoutCell(name: "EMPTY", shapes: [empty])) }
    }
    @Test func admissionHasExactSuccessAndFailureBoundaries() throws {
        let one = LayoutCell(name: "ONE", shapes: [shape(0)])
        let exact = LayoutConductorCaptureLimits(decomposition: .init(maximumInputEntries: 5, maximumEdgeProbes: 4, maximumOutputBands: 1), maximumTechnologyRecords: 6, maximumFootprints: 1, maximumContactProbes: 0)
        #expect(try capture(one, limits: exact).components.count == 1)
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.technologyRecords)) { try capture(one, limits: .init(maximumTechnologyRecords: 5)) }
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.footprints)) { try capture(one, limits: .init(maximumFootprints: 0)) }
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.contactProbes)) { try capture(LayoutCell(name: "PAIR", shapes: [shape(0), shape(0)]), limits: .init(maximumContactProbes: 0)) }
        #expect(throws: LayoutConductorCaptureError.decompositionFailed(.limitExceeded(.inputEntries))) {
            try capture(one, limits: .init(decomposition: .init(maximumInputEntries: 4, maximumEdgeProbes: 4, maximumOutputBands: 1)))
        }
    }
    @Test func cancellationLateInCaptureDoesNotPublishPartialFacts() throws {
        let source = document(LayoutCell(name: "CANCEL", shapes: (0..<8).map { shape(Double($0)) }))
        let extractor = LayoutConnectivityExtractor()
        var checks = 0
        _ = try extractor.captureConductors(document: source, tech: .standard(), conductiveLayers: layers, isCancelled: { checks += 1; return false })
        let threshold = checks - 3
        checks = 0
        var output: LayoutConductorSnapshot?
        #expect(throws: LayoutConductorCaptureError.cancelled) {
            output = try extractor.captureConductors(document: source, tech: .standard(), conductiveLayers: layers, isCancelled: { checks += 1; return checks >= threshold })
        }
        #expect(output == nil)
    }
    @Test func unknownAndConflictingTerminalBindingsAreRejected() {
        let local = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: local)
        var child = LayoutCell(name: "CHILD", shapes: [shape(0, net: local)], pins: [pin])
        var top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "child", terminalNetIDs: ["UNKNOWN": UUID()])])
        let extractor = LayoutConnectivityExtractor()
        #expect(throws: LayoutConductorCaptureError.unknownTerminal(occurrenceIndex: 1, name: "UNKNOWN")) {
            try extractor.captureConductors(document: document(top, children: [child]), tech: .standard(), conductiveLayers: layers)
        }
        child.pins.append(LayoutPin(name: "Q", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: local))
        top.instances[0].terminalNetIDs = ["P": UUID(), "Q": UUID()]
        #expect(throws: LayoutConductorCaptureError.conflictingTerminalBinding(occurrenceIndex: 1, netID: local)) {
            try extractor.captureConductors(document: document(top, children: [child]), tech: .standard(), conductiveLayers: layers)
        }
    }
    @Test func nestedBindingsResolveToTheRootNet() throws {
        let rootNet = UUID(), middleNet = UUID(), leafNet = UUID()
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1, netID: leafNet)
        let leaf = LayoutCell(name: "LEAF", shapes: [shape(0, net: leafNet)], pins: [pin])
        var middlePin = pin; middlePin.netID = middleNet
        let middle = LayoutCell(name: "MIDDLE", pins: [middlePin], instances: [
            LayoutInstance(cellID: leaf.id, name: "leaf", terminalNetIDs: ["P": middleNet])
        ])
        let root = LayoutCell(name: "ROOT", instances: [
            LayoutInstance(cellID: middle.id, name: "middle", terminalNetIDs: ["P": rootNet])
        ])
        let result = try LayoutConnectivityExtractor().captureConductors(document: document(root, children: [middle, leaf]),
            tech: .standard(), conductiveLayers: layers)
        #expect(result.components.count == 1 && result.components[0].declaredNets.count == 1)
        #expect(result.components[0].declaredNets[0].occurrenceIndex == 0)
        #expect(result.components[0].declaredNets[0].netID == rootNet)
        #expect(result.pins.count == 2 && result.opens.isEmpty && result.shortComponentIndices.isEmpty)
    }

    @Test func stitchedHoleKeepsFloatingInteriorSeparate() throws {
        let points: [LayoutPoint] = [(0.0, 0.0), (6, 0), (6, 6), (0, 6), (0, 0),
                                    (2, 0), (2, 2), (2, 4), (4, 4), (4, 2), (2, 2), (2, 0), (0, 0)]
            .map { LayoutPoint(x: $0.0, y: $0.1) }
        let outer = LayoutShape(layer: m1, geometry: .polygon(.init(points: points)))
        let inner = LayoutShape(layer: m1, geometry: .rect(rect(2.5, 2.5)))
        let result = try capture(LayoutCell(name: "HOLE", shapes: [outer, inner]))
        #expect(result.components.count == 2)
        #expect(result.components[0].footprintIndices.count == 5)
        #expect(result.components[1].footprintIndices.count == 1)
        #expect(result.components.allSatisfy { $0.declaredNets.isEmpty })
    }

    @Test func duplicateAndAmbiguousTechnologyCannotChooseFirstEntry() {
        let cell = LayoutCell(name: "TECH", shapes: [shape(0)])
        var duplicate = LayoutTechDatabase.standard(); duplicate.vias.append(duplicate.vias[0])
        #expect(throws: LayoutConductorCaptureError.duplicateTechnologyID("VIA1")) { try capture(cell, tech: duplicate) }
        var ambiguous = LayoutTechDatabase.standard()
        var alternate = ambiguous.vias[0]; alternate.id = "OTHER"; alternate.topLayer = .init(name: "M3", purpose: "drawing")
        ambiguous.vias.append(alternate)
        #expect(throws: LayoutConductorCaptureError.ambiguousLayerRole(cut)) { try capture(cell, tech: ambiguous) }
        var missing = LayoutTechDatabase.standard(); missing.layers.removeLast()
        #expect(throws: LayoutConductorCaptureError.ambiguousLayerRole(cut)) {
            try capture(LayoutCell(name: "MISSING_CUT", shapes: [shape(0, layer: cut)]), tech: missing)
        }
    }

    @Test func checkedGridRejectsOverflowAndRetainsInt32Edges() throws {
        let outOfRange = shape(Double(Int32.max) / 1000)
        #expect(throws: LayoutConductorCaptureError.invalidGridGeometry(outOfRange.id)) {
            try capture(LayoutCell(name: "OVERFLOW", shapes: [outOfRange]))
        }
        let edge = LayoutShape(layer: m1, geometry: .rect(rect(Double(Int32.max - 1000) / 1000, 0)))
        let result = try capture(LayoutCell(name: "EDGE", shapes: [edge]))
        #expect(result.footprints[0].band.maxX == Int32.max)
        let arithmetic = LayoutShape(layer: m1, geometry: .rect(rect(0.1 + 0.2, 0, 0.1, 0.1)))
        #expect(try capture(LayoutCell(name: "ARITHMETIC", shapes: [arithmetic])).footprints[0].band.minX == 300)
    }

    @Test func contactAndPinProbesHaveExactBudgetBoundaries() throws {
        let pair = LayoutCell(name: "PAIR", shapes: [shape(0), shape(1)])
        #expect(try capture(pair, limits: .init(maximumContactProbes: 1)).contacts.count == 1)
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 0.2, height: 0.2), layer: m1)
        let pinned = LayoutCell(name: "PIN", shapes: [shape(0)], pins: [pin])
        #expect(try capture(pinned, limits: .init(maximumContactProbes: 1)).pins[0].componentIndices == [0])
        #expect(throws: LayoutConductorCaptureError.limitExceeded(.contactProbes)) {
            try capture(pinned, limits: .init(maximumContactProbes: 0))
        }
        #expect(throws: LayoutConductorCaptureError.decompositionFailed(.limitExceeded(.edgeProbes))) {
            try capture(pair, limits: .init(decomposition: .init(maximumInputEntries: 10, maximumEdgeProbes: 7, maximumOutputBands: 2)))
        }
        #expect(throws: LayoutConductorCaptureError.decompositionFailed(.limitExceeded(.outputBands))) {
            try capture(pair, limits: .init(decomposition: .init(maximumInputEntries: 10, maximumEdgeProbes: 8, maximumOutputBands: 1)))
        }
    }

    @Test func actualTaskCancellationUsesTheDefaultGuard() async throws {
        let source = document(LayoutCell(name: "CANCEL", shapes: [shape(0)]))
        let selectedLayers = layers
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LayoutConnectivityExtractor().captureConductors(document: source, tech: .standard(), conductiveLayers: selectedLayers)
        }
        do { _ = try await task.value; Issue.record("Cancelled capture must fail before publishing facts") }
        catch let error as LayoutConductorCaptureError { #expect(error == .cancelled) }
    }

}
