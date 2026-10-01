import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Bounded hierarchy capture", .timeLimit(.minutes(1)))
struct HierarchyCaptureTests {
    @Test func missingChildCannotBecomeEmptyConnectivitySuccess() {
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: UUID(), name: "missing")])
        let document = LayoutDocument(name: "invalid", cells: [top], topCellID: top.id)
        #expect(throws: (any Error).self) {
            try LayoutConnectivityExtractor().extract(document: document, tech: .standard())
        }
    }
}

extension HierarchyCaptureTests {
    private var metal: LayoutLayerID { LayoutLayerID(name: "M1", purpose: "drawing") }

    private func shape() -> LayoutShape {
        LayoutShape(layer: metal, geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 2, height: 1))))
    }

    private func document(_ cell: LayoutCell, children: [LayoutCell] = []) -> LayoutDocument {
        LayoutDocument(name: "capture", cells: [cell] + children, topCellID: cell.id)
    }

    @Test func nestedArraysKeepOccurrenceIdentityGeometryAndRanges() throws {
        let pin = LayoutPin(name: "P", position: LayoutPoint(x: 1, y: 0.5),
                            size: LayoutSize(width: 2, height: 1), layer: metal)
        let sourceShape = shape()
        let sourceVia = LayoutVia(viaDefinitionID: "VIA1", position: .zero)
        let leaf = LayoutCell(name: "LEAF", shapes: [sourceShape], vias: [sourceVia], pins: [pin])
        let array = LayoutInstance(cellID: leaf.id, name: "array", repetition: LayoutRepetition(
            columns: 2, rows: 1, columnStep: LayoutPoint(x: 10, y: 0), rowStep: .zero))
        let middle = LayoutCell(name: "MID", instances: [array])
        let outer = LayoutInstance(cellID: middle.id, name: "outer", transform: LayoutTransform(
            translation: LayoutPoint(x: 30, y: 20), rotation: .deg90, magnification: 2, mirrorX: true))
        let top = LayoutCell(name: "TOP", instances: [outer])
        var source = document(top, children: [middle, leaf])
        let captured = try LayoutConnectivityExtractor().captureHierarchy(document: source)
        #expect(captured.occurrences.count == 4)
        #expect(captured.shapes.map(\.id) == [sourceShape.id, sourceShape.id])
        #expect(captured.shapes.allSatisfy { $0.netID == nil })
        #expect(captured.occurrences[2].path.map(\.instanceID) == [outer.id, array.id])
        #expect(captured.occurrences[2].path.last?.column == 0)
        #expect(captured.occurrences[3].path.last?.column == 1)
        #expect(captured.occurrences[2].parentIndex == 1)
        #expect(captured.occurrences[2].shapeRange == 0..<1)
        #expect(captured.occurrences[3].shapeRange == 1..<2)
        #expect(LayoutGeometryAnalysis.boundingBox(for: captured.shapes[0].geometry)
                == LayoutRect(origin: LayoutPoint(x: 28, y: 16), size: LayoutSize(width: 2, height: 4)))
        #expect(captured.vias[1].position == LayoutPoint(x: 30, y: 0))
        #expect(captured.pins[0].size == LayoutSize(width: 2, height: 4))
        #expect(captured.pinGeometries.count == 2)
        source.cells[2].shapes.removeAll()
        #expect(captured.shapes.count == 2)
    }

    @Test func pathWidthAndPinRectangleFollowFullAffineTransform() throws {
        let path = LayoutShape(layer: metal, geometry: .path(LayoutPath(
            points: [.zero, LayoutPoint(x: 2, y: 0)], width: 0.5, endCap: .truncate)))
        let pin = LayoutPin(name: "P", position: .zero, size: LayoutSize(width: 2, height: 1), layer: metal)
        let leaf = LayoutCell(name: "LEAF", shapes: [path], pins: [pin])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: leaf.id, name: "placed",
            transform: LayoutTransform(rotationDegrees: 45, magnification: 3, mirrorX: true))])
        let capture = try LayoutConnectivityExtractor().captureHierarchy(document: document(top, children: [leaf]))
        guard case .path(let worldPath) = capture.shapes[0].geometry else {
            Issue.record("Path representation must survive capture"); return
        }
        #expect(worldPath.width == 1.5)
        #expect(worldPath.endCap == .truncate)
        #expect(abs(worldPath.points[1].x + 3 * sqrt(2)) < 1e-12)
        #expect(abs(worldPath.points[1].y + 3 * sqrt(2)) < 1e-12)
        guard case .polygon(let polygon) = capture.pinGeometries[0] else {
            Issue.record("Rotated pin must retain its polygon"); return
        }
        #expect(polygon.points.count == 4)
        #expect(polygon.points[0].x != polygon.points[1].x && polygon.points[0].y != polygon.points[1].y)
    }

    @Test func terminalMappingsRemainSourceFactsAndLegacyResolutionStillWorks() throws {
        let net = UUID()
        let wire = shape()
        let pin = LayoutPin(name: "P", position: LayoutPoint(x: 1, y: 0.5), size: LayoutSize(width: 1, height: 0.5), layer: metal)
        let child = LayoutCell(name: "CHILD", shapes: [wire], pins: [pin])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "bound", terminalNetIDs: ["P": net])])
        let source = document(top, children: [child])
        let capture = try LayoutConnectivityExtractor().captureHierarchy(document: source)
        #expect(capture.occurrences[1].terminalNetIDs == ["P": net])
        #expect(capture.shapes[0].netID == nil && capture.pins[0].netID == nil)
        let flat = try LayoutConnectivityExtractor().flattenedConductors(document: source, tech: .standard())
        #expect(flat.shapes[0].netID == net && flat.pins[0].netID == net)
    }

    @Test func cycleFailsAcrossCaptureBatchLiveAndDRC() throws {
        let id = UUID()
        let cell = LayoutCell(id: id, name: "CYCLE", instances: [LayoutInstance(cellID: id, name: "self")])
        let source = document(cell)
        let expected = LayoutHierarchyCaptureError.hierarchyCycle(id)
        #expect(throws: expected) { try LayoutConnectivityExtractor().captureHierarchy(document: source) }
        #expect(throws: expected) { try LayoutConnectivityExtractor().extract(document: source, tech: .standard()) }
        #expect(throws: expected) { try LiveConnectivitySession(document: source, tech: .standard()) }
        #expect(throws: expected) { try DeviceExtractor().extract(document: source, tech: .standard()) }
        #expect(LayoutDRCService().run(document: source, tech: .standard()).diagnostics.first?.code == "drc.hierarchy_cycle")
        #expect(throws: LayoutDRCServiceError.hierarchyCaptureFailed(expected)) {
            try LayoutDRCService().runChecked(document: source, tech: .standard())
        }
    }

    @Test func finiteDegeneratePolygonsRemainSourceFacts() throws {
        let geometries: [LayoutGeometry] = [
            .polygon(LayoutPolygon(points: [])),
            .polygon(LayoutPolygon(points: [LayoutPoint(x: 1, y: 1), LayoutPoint(x: 2, y: 2)])),
            .polygon(LayoutPolygon(points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 1, y: 0), LayoutPoint(x: 2, y: 0)]))
        ]
        let cell = LayoutCell(name: "DEGENERATE", shapes: geometries.map { LayoutShape(layer: metal, geometry: $0) })
        let capture = try LayoutConnectivityExtractor().captureHierarchy(document: document(cell))
        #expect(capture.shapes.map(\.geometry) == geometries)
        #expect(capture.shapes.map(\.id) == cell.shapes.map(\.id))
    }

    @Test func duplicateCellsAndLocalObjectsAreRejected() {
        let wire = shape()
        let cell = LayoutCell(name: "TOP", shapes: [wire, wire])
        #expect(throws: LayoutHierarchyCaptureError.duplicateObjectID(cellID: cell.id, objectID: wire.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(cell))
        }
        var source = document(LayoutCell(name: "TOP"))
        source.cells.append(source.cells[0])
        #expect(throws: LayoutHierarchyCaptureError.duplicateCellID(source.cells[0].id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: source)
        }
    }

    @Test(arguments: [0, -1]) func malformedRepetitionCannotClampOrDisappear(rows: Int) {
        let leaf = LayoutCell(name: "LEAF")
        var repetition = LayoutRepetition(columns: 1, rows: 1, columnStep: .zero, rowStep: .zero)
        repetition.rows = rows
        let instance = LayoutInstance(cellID: leaf.id, name: "bad", repetition: repetition)
        let top = LayoutCell(name: "TOP", instances: [instance])
        #expect(throws: LayoutHierarchyCaptureError.invalidRepetition(instance.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(top, children: [leaf]))
        }
    }

    @Test func overflowingAndExcessiveArraysFailBeforeExpansion() {
        let leaf = LayoutCell(name: "LEAF")
        let instance = LayoutInstance(cellID: leaf.id, name: "overflow", repetition: LayoutRepetition(
            columns: Int.max, rows: 2, columnStep: .zero, rowStep: .zero))
        let top = LayoutCell(name: "TOP", instances: [instance])
        #expect(throws: LayoutHierarchyCaptureError.repetitionOverflow(instance.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(top, children: [leaf]))
        }
        var bounded = top
        bounded.instances[0].repetition?.rows = 1
        #expect(throws: LayoutHierarchyCaptureError.limitExceeded(.occurrences)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(bounded, children: [leaf]))
        }
    }

    @Test func eachAdmissionLimitHasAnExactBoundary() throws {
        let top = LayoutCell(name: "TOP", shapes: [shape()])
        let source = document(top)
        let exact = LayoutHierarchyCaptureLimits(maximumOccurrences: 1, maximumObjects: 1, maximumGeometryPoints: 4, maximumDepth: 0)
        #expect(try LayoutConnectivityExtractor().captureHierarchy(document: source, limits: exact).shapes.count == 1)
        #expect(throws: LayoutHierarchyCaptureError.limitExceeded(.objects)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: source,
                limits: .init(maximumOccurrences: 1, maximumObjects: 0, maximumGeometryPoints: 4, maximumDepth: 0))
        }
        #expect(throws: LayoutHierarchyCaptureError.limitExceeded(.geometryPoints)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: source,
                limits: .init(maximumOccurrences: 1, maximumObjects: 1, maximumGeometryPoints: 3, maximumDepth: 0))
        }
        let parent = LayoutCell(name: "PARENT", instances: [LayoutInstance(cellID: top.id, name: "child")])
        #expect(throws: LayoutHierarchyCaptureError.limitExceeded(.depth)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(parent, children: [top]),
                limits: .init(maximumOccurrences: 2, maximumObjects: 2, maximumGeometryPoints: 100, maximumDepth: 0))
        }
        #expect(throws: LayoutHierarchyCaptureError.invalidLimits) {
            try LayoutConnectivityExtractor().captureHierarchy(document: source,
                limits: .init(maximumOccurrences: -1, maximumObjects: 1, maximumGeometryPoints: 4, maximumDepth: 0))
        }
    }

    @Test func nonfiniteAndOverflowingWorldGeometryFail() {
        var wire = shape()
        wire.geometry = .rect(LayoutRect(origin: LayoutPoint(x: .infinity, y: 0), size: LayoutSize(width: 1, height: 1)))
        #expect(throws: LayoutHierarchyCaptureError.invalidGeometry(wire.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(LayoutCell(name: "TOP", shapes: [wire])))
        }
        let giant = LayoutShape(layer: metal, geometry: .rect(LayoutRect(
            origin: .zero, size: LayoutSize(width: 1e308, height: 1))))
        let leaf = LayoutCell(name: "LEAF", shapes: [giant])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: leaf.id, name: "scaled",
            transform: LayoutTransform(magnification: 2))])
        #expect(throws: LayoutHierarchyCaptureError.invalidGeometry(giant.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(top, children: [leaf]))
        }
    }

    @Test(arguments: [0.0, Double.nan]) func invalidTransformFails(magnification: Double) {
        let leaf = LayoutCell(name: "LEAF")
        let instance = LayoutInstance(cellID: leaf.id, name: "bad", transform: LayoutTransform(magnification: magnification))
        #expect(throws: LayoutHierarchyCaptureError.invalidTransform(instance.id)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(LayoutCell(name: "TOP", instances: [instance]), children: [leaf]))
        }
    }

    @Test func cancellationDuringCaptureNeverReturnsPartialGeometry() {
        let top = LayoutCell(name: "TOP", shapes: (0..<20).map { _ in shape() })
        var checks = 0
        #expect(throws: LayoutHierarchyCaptureError.cancelled) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(top), isCancelled: {
                checks += 1
                return checks > 15
            })
        }
        #expect(top.shapes.count == 20)
        #expect(throws: LayoutHierarchyCaptureError.cancelled) {
            try LayoutConnectivityExtractor().captureHierarchy(document: document(top), isCancelled: { true })
        }
    }

    @Test func depthAdmissionIsIterativeAndExplicit() throws {
        var cells = [LayoutCell(name: "LEAF", shapes: [shape()])]
        for index in 0..<100 {
            cells.append(LayoutCell(name: "C\(index)", instances: [LayoutInstance(cellID: cells.last!.id, name: "child")]))
        }
        let source = LayoutDocument(name: "deep", cells: cells, topCellID: cells.last!.id)
        #expect(throws: LayoutHierarchyCaptureError.limitExceeded(.depth)) {
            try LayoutConnectivityExtractor().captureHierarchy(document: source)
        }
        let captured = try LayoutConnectivityExtractor().captureHierarchy(document: source,
            limits: .init(maximumOccurrences: 101, maximumObjects: 101, maximumGeometryPoints: 30_000, maximumDepth: 100))
        #expect(captured.occurrences.count == 101)
        #expect(captured.occurrences.last?.path.count == 100)
    }
}

extension HierarchyCaptureTests {
    @Test func taskCancellationUsesDefaultCaptureGuard() async throws {
        let source = document(LayoutCell(name: "TOP", shapes: [shape()]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LayoutConnectivityExtractor().captureHierarchy(document: source)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled capture task must not return success")
        } catch let error as LayoutHierarchyCaptureError {
            #expect(error == .cancelled)
        }
    }
}
