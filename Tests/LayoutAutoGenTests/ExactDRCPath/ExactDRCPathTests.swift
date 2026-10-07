import Foundation
import CircuiteFoundation
import LayoutCore
import LayoutTech
import LayoutAutoGen
import LayoutIR
import MaskGeometry
import Testing
@testable import LayoutVerify

@Suite("Exact DRC canonical PATH admission", .timeLimit(.minutes(1)))
struct ExactDRCPathTests {
    private var metal: LayoutLayerID { .init(name: "M1", purpose: "drawing") }

    private func technology(width: Double = 0, spacing: Double = 0,
                            rectangular: Bool = false) -> LayoutTechDatabase {
        .init(grid: 0.001, layers: [.init(id: metal, displayName: "M1", gdsLayer: 1,
            gdsDatatype: 0, color: .gray)], vias: [], layerRules: [.init(layerID: metal,
            minWidth: width, minSpacing: spacing, minArea: 0, minDensity: 0,
            maxDensity: 1, requiresRectangular: rectangular, allowedAngleStepDegrees: 90)])
    }

    private func path(_ points: [LayoutPoint], width: Double = 1,
                      cap: LayoutPathEndCap = .truncate) -> LayoutShape {
        .init(layer: metal, geometry: .path(.init(points: points, width: width, endCap: cap)))
    }

    private func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutShape {
        .init(layer: metal, geometry: .rect(.init(origin: .init(x: x, y: y),
            size: .init(width: width, height: height))))
    }

    private func document(_ shapes: [LayoutShape], pins: [LayoutPin] = []) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes, pins: pins)
        return .init(name: "exact-path", cells: [cell], topCellID: cell.id)
    }

    private func prepare(_ source: LayoutDocument, tech: LayoutTechDatabase,
                         unionLimits: RectilinearUnionLimits? = nil,
                         isCancelled: () -> Bool = { false }) throws -> ExactDRCGeometry {
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: source,
            tech: tech, conductiveLayers: [metal])
        return try ExactDRCGeometry(snapshot: snapshot, limits: .default,
            unionLimits: unionLimits, isCancelled: isCancelled)
    }

    private func assertCoverage(_ shape: LayoutShape, rectangles: [LayoutShape],
                                tech: LayoutTechDatabase) throws {
        let source = document([shape])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(source)
        let prepared = try prepare(source, tech: tech)
        let dbu = prepared.coordinateUnits.scale.databaseUnitsPerMicrometer
        var boundaries: [IRBoundary] = []
        for rectangle in rectangles {
            boundaries.append(contentsOf: try ExactDRCGeometry.primitiveRegion(rectangle.geometry,
                dbu: dbu).polygons)
        }
        let independent = try Region(polygons: boundaries).union(Region())
        #expect(try prepared.entries[0].region.symmetricDifference(independent).isEmpty)
        let result = try LayoutDRCService().runChecked(document: source, tech: tech)
        #expect(result.diagnostics.isEmpty && result.violations.isEmpty)
        #expect(result.sourceHierarchy?.shapes == [shape])
        #expect(try encoder.encode(source) == originalBytes)
        #expect(prepared.entries[0].shape == shape)
    }

    @Test(arguments: [LayoutPathEndCap.truncate, .extend, .custom(begin: -0.25, end: 0.75)])
    func straightSignedCapsAndReversalMatchIndependentRectangle(cap: LayoutPathEndCap) throws {
        let extensions: (Double, Double)
        switch cap {
        case .truncate: extensions = (0, 0)
        case .extend: extensions = (0.5, 0.5)
        case .custom(let begin, let end): extensions = (begin, end)
        case .round: Issue.record("Round cap is outside this admitted fixture"); return
        }
        let oracle = [rectangle(-extensions.0, -0.5, 2 + extensions.0 + extensions.1, 1)]
        try assertCoverage(path([.zero, .init(x: 2, y: 0)], cap: cap), rectangles: oracle,
            tech: technology(rectangular: true))
        let reversedCap = LayoutPathEndCap.custom(begin: extensions.1, end: extensions.0)
        try assertCoverage(path([.init(x: 2, y: 0), .zero], cap: reversedCap),
            rectangles: oracle, tech: technology(rectangular: true))
    }

    @Test func miterCoverageMatchesIndependentRectangleUnionAndWholeSourceRectRule() throws {
        let shape = path([.zero, .init(x: 2, y: 0), .init(x: 2, y: 2)],
            cap: .custom(begin: 0.25, end: 0.75))
        try assertCoverage(shape, rectangles: [rectangle(-0.25, -0.5, 2.25, 1),
            rectangle(1.5, 0, 1, 2.75), rectangle(1.5, -0.5, 1, 1)], tech: technology())
        let result = try LayoutDRCService().runChecked(document: document([shape]),
            tech: technology(rectangular: true))
        #expect(result.violations.contains { $0.kind == .rectOnly && $0.shapeIDs == [shape.id] })
    }

    @Test func oddWidthUsesCapturedHalfGridDespiteDifferentTechnologyUnits() throws {
        let shape = path([.zero, .init(x: 0.003, y: 0)], width: 0.001, cap: .extend)
        var tech = technology(width: 0.001)
        tech.units = try .init(scale: DatabaseUnitScale(databaseUnitsPerMicrometer: 100))
        try assertCoverage(shape, rectangles: [rectangle(-0.0005, -0.0005, 0.004, 0.001)], tech: tech)
        let prepared = try prepare(document([shape]), tech: tech)
        #expect(prepared.coordinateUnits.scale.databaseUnitsPerMicrometer == 2_000)
        #expect(tech.units.scale.databaseUnitsPerMicrometer == 100)
    }

    @Test func repeatedSourceUUIDsRetainDistinctOccurrenceRegionsAndOriginalHierarchy() throws {
        let shape = path([.zero, .init(x: 2, y: 0)], width: 0.24, cap: .extend)
        let child = LayoutCell(name: "CHILD", shapes: [shape])
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: child.id, name: "A"),
            .init(cellID: child.id, name: "B", transform: .init(translation: .init(x: 5, y: 3)))])
        let source = LayoutDocument(name: "hierarchy", cells: [top, child], topCellID: top.id)
        let tech = technology(width: 0.23, spacing: 0.23)
        let prepared = try prepare(source, tech: tech)
        #expect(prepared.entries.count == 2)
        #expect(prepared.entries.map(\.shape.id) == [shape.id, shape.id])
        #expect(Set(prepared.entries.map(\.occurrenceIndex)).count == 2)
        #expect(prepared.entries.map(\.flattenedIndex) == [0, 1])
        #expect(prepared.entries[0].region != prepared.entries[1].region)
        let result = try LayoutDRCService().runChecked(document: source, tech: tech)
        #expect(result.violations.isEmpty && result.diagnostics.isEmpty)
        #expect(result.sourceHierarchy?.shapes == prepared.entries.map(\.shape))
        #expect(source.cells[1].shapes[0] == shape)
    }

    @Test func actualWidthAndSpacingViolationsKeepOriginalPATHIDs() throws {
        let first = path([.zero, .init(x: 2, y: 0)], width: 0.1)
        let second = path([.init(x: 0, y: 0.2), .init(x: 2, y: 0.2)], width: 0.1)
        let result = try LayoutDRCService().runChecked(document: document([first, second]),
            tech: technology(width: 0.2, spacing: 0.2))
        #expect(result.violations.contains { $0.kind == .minWidth && $0.shapeIDs.contains(first.id) })
        #expect(result.violations.contains { $0.kind == .minSpacing && Set($0.shapeIDs) == [first.id, second.id] })
        #expect(result.sourceHierarchy?.shapes == [first, second])
    }

    @Test func actualStagedAntennaUsesCapCoverageAndUnionArea() throws {
        let points = [LayoutPoint.zero, .init(x: 2, y: 0)]
        let extended = path(points, width: 1, cap: .extend)
        let gate = LayoutPin(name: "G", position: .init(x: -0.25, y: 0),
            size: .init(width: 0.1, height: 0.1), layer: metal, role: .gate)
        var tech = LayoutTechDatabase.standard()
        tech.layerRules = [.init(layerID: metal, minWidth: 0, minSpacing: 0, minArea: 0,
            minDensity: 0, maxDensity: 1)]
        tech.enclosureRules = []; tech.extensionRules = []; tech.spacingRules = []
        tech.derivedLayerRules = []
        tech.antennaRules = [.init(layerID: metal, maxRatio: 10)]
        let result = try LayoutDRCService().runChecked(document: document([extended], pins: [gate]), tech: tech)
        let antenna = try #require(result.violations.first { $0.kind == .antenna })
        #expect(abs((antenna.measured ?? 0) - 300) < 1e-9)
        #expect(antenna.shapeIDs == [extended.id] && antenna.pinIDs == [gate.id])
        let flush = path(points, width: 1, cap: .truncate)
        let disconnected = try LayoutDRCService().runChecked(document: document([flush], pins: [gate]), tech: tech)
        #expect(!disconnected.violations.contains { $0.kind == .antenna })
    }

    @Test(arguments: [false, true])
    func capturedPinAndViaContactsIncludeEdgesAndCornersAtTheirOwnStage(corner: Bool) throws {
        let upper = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        var tech = technology()
        tech.layers.append(contentsOf: [
            .init(id: upper, displayName: "M2", gdsLayer: 2, gdsDatatype: 0, color: .gray),
            .init(id: cut, displayName: "VIA1", gdsLayer: 3, gdsDatatype: 0, color: .gray)])
        tech.layerRules.append(.init(layerID: upper, minWidth: 0, minSpacing: 0,
            minArea: 0, minDensity: 0, maxDensity: 1))
        tech.vias = [.init(id: "VIA1", cutLayer: cut, topLayer: upper, bottomLayer: metal,
            cutSize: .init(width: 0.2, height: 0.2), enclosure: .init(top: 0, bottom: 0), cutSpacing: 0.2)]
        tech.antennaRules = [.init(layerID: metal, maxRatio: 0.5), .init(layerID: upper, maxRatio: 10)]
        let gate = LayoutPin(name: "gate", position: .init(x: -0.1, y: corner ? -0.1 : 0.1),
            size: .init(width: 0.2, height: 0.2), layer: metal, role: .gate)
        let lowerShape = rectangle(0, 0, 0.2, 0.2)
        let upperShape = LayoutShape(layer: upper, geometry: .rect(.init(
            origin: .init(x: 0.4, y: corner ? 0.4 : 0), size: .init(width: 1, height: 1))))
        let via = LayoutVia(viaDefinitionID: "VIA1", position: .init(x: 0.3, y: corner ? 0.3 : 0.1))
        let cell = LayoutCell(name: "TOP", shapes: [lowerShape, upperShape], vias: [via], pins: [gate])
        let source = LayoutDocument(name: "exact-antenna-contact", cells: [cell], topCellID: cell.id)
        let original = source
        let result = try LayoutDRCService().runChecked(document: source, tech: tech)
        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 2)
        let lowerViolation = try #require(violations.first { $0.layer == metal })
        let upperViolation = try #require(violations.first { $0.layer == upper })
        // Independent areas: 0.04 / 0.04 at M1 and 1 / 0.04 at M2.
        #expect(abs((lowerViolation.measured ?? 0) - 1) < 1e-9)
        #expect(abs((upperViolation.measured ?? 0) - 25) < 1e-9)
        #expect(lowerViolation.shapeIDs == [lowerShape.id] && lowerViolation.pinIDs == [gate.id])
        #expect(lowerViolation.viaIDs.isEmpty)
        #expect(upperViolation.shapeIDs == [upperShape.id] && upperViolation.pinIDs == [gate.id])
        #expect(upperViolation.viaIDs == [via.id])
        #expect(source == original && result.sourceHierarchy?.pins == [gate])

        let tie = LayoutPin(name: "late-discharge", position: .init(x: 0.9, y: corner ? 0.9 : 0.5),
            size: .init(width: 0.2, height: 0.2), layer: upper, role: .source)
        var discharged = source
        discharged.cells[0].pins.append(tie)
        let late = try LayoutDRCService().runChecked(document: discharged, tech: tech)
        let earlyViolations = late.violations.filter { $0.kind == .antenna }
        #expect(earlyViolations.count == 1)
        #expect(earlyViolations.first?.layer == metal && earlyViolations.first?.shapeIDs == [lowerShape.id])
    }

    @Test func aggregateUnionBudgetRefusesSecondPATHInsteadOfResettingPerSource() throws {
        let shapes = [path([.zero, .init(x: 2, y: 0)]),
                      path([.init(x: 0, y: 3), .init(x: 2, y: 3)])]
        let policy = RectilinearUnionLimits(maximumInputEntries: 100, maximumEdgeProbes: 100,
            maximumIntermediateBands: 100, maximumSweepWork: 100, maximumOutputBands: 1)
        _ = try LayoutDRCService().runChecked(document: document([shapes[0]]),
            tech: technology(), pathUnionLimits: policy)
        #expect(throws: RectilinearDecompositionError.limitExceeded(.outputBands)) {
            try LayoutDRCService().runChecked(document: document(shapes), tech: technology(), pathUnionLimits: policy)
        }
        let refused = LayoutDRCService().run(document: document(shapes), tech: technology(),
            geometryMode: .exactOnly, pathUnionLimits: policy)
        #expect(refused.hasErrors && refused.violations.isEmpty && refused.sourceHierarchy == nil)
    }

    @Test func offGridOverflowThresholdCancellationAndUnsupportedInputsRefuse() throws {
        let tech = technology()
        let offGrid = path([.zero, .init(x: 2.0001, y: 0)])
        #expect(throws: LayoutConductorCaptureError.self) {
            try LayoutDRCService().runChecked(document: document([offGrid]), tech: tech)
        }
        let overflow = path([.init(x: 2_000_000, y: 0), .init(x: 2_000_001, y: 0)])
        #expect(throws: LayoutConductorCaptureError.self) {
            try LayoutDRCService().runChecked(document: document([overflow]), tech: tech)
        }
        let valid = path([.zero, .init(x: 2, y: 0)])
        #expect(throws: ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)) {
            try LayoutDRCService().runChecked(document: document([valid]), tech: technology(width: 0.0001))
        }
        #expect(throws: ExactDRCGeometryError.cancelled) {
            try prepare(document([valid]), tech: tech, isCancelled: { true })
        }
        #expect(throws: LayoutDRCServiceError.hierarchyCaptureFailed(.cancelled)) {
            try LayoutDRCService().runChecked(document: document([valid]), tech: tech, isCancelled: { true })
        }
        for invalid in [path([.zero, .init(x: 2, y: 1)]),
                        path([.zero, .init(x: 2, y: 0)], cap: .round)] {
            #expect(throws: LayoutConductorCaptureError.self) {
                try LayoutDRCService().runChecked(document: document([invalid]), tech: tech)
            }
        }
    }

    @Test(arguments: [LayoutElectricalContext.geometric, .deviceAwareMOS,
        .deviceAwareMOSAndPolyResistors(polyLayer: ResistorCellGenerator.polyLayerID,
            bodyMarkerLayer: ResistorCellGenerator.bodyMarkerLayerID)])
    func nonTaskCancellationReachesElectricalCaptureBeforeExactPreparation(context: LayoutElectricalContext) throws {
        let cell = try ResistorCellGenerator().generateCell(deviceKindID: "resistor", instanceName: "R",
            parameters: ["r": 1_000], tech: .sampleProcess())
        let source = LayoutDocument(name: "cancellation", cells: [cell], topCellID: cell.id)
        let tech = LayoutTechDatabase.sampleProcess()
        let baseline = try LayoutDRCService().runChecked(document: source, tech: tech,
            electricalContext: context)
        #expect(baseline.sourceHierarchy != nil && baseline.diagnostics.isEmpty)
        var firstHierarchyChecks = 0
        _ = try LayoutConnectivityExtractor().captureHierarchy(document: source,
            isCancelled: { firstHierarchyChecks += 1; return false })
        #expect(!Task.isCancelled)
        var checks = 0
        var completed: LayoutDRCResult?
        func cancelledAfterFirstHierarchy() -> Bool {
            checks += 1
            return checks > firstHierarchyChecks
        }
        switch context {
        case .geometric:
            #expect(throws: LayoutConductorCaptureError.cancelled) {
                completed = try LayoutDRCService().runChecked(document: source, tech: tech,
                    electricalContext: context, isCancelled: cancelledAfterFirstHierarchy)
            }
        case .deviceAwareMOS, .deviceAwareMOSAndPolyResistors:
            #expect(throws: LayoutDRCServiceError.hierarchyCaptureFailed(.cancelled)) {
                completed = try LayoutDRCService().runChecked(document: source, tech: tech,
                    electricalContext: context, isCancelled: cancelledAfterFirstHierarchy)
            }
        }
        #expect(checks == firstHierarchyChecks + 1 && completed == nil)
    }
}
