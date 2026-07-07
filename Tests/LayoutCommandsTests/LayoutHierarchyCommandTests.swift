import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import Testing

@Suite("Layout hierarchy commands")
struct LayoutHierarchyCommandTests {
    private let serializer = LayoutDocumentSerializer()

    @Test("Rotate instance supports explicit pivot")
    func rotateInstanceSupportsExplicitPivot() throws {
        let ids = TestIDs(prefix: "20000000")
        let root = try temporaryRoot("rotate-pivot")
        let request = LayoutCommandRequest(
            documentID: ids.document,
            outputDocumentPath: "layout.json",
            commands: [
                .createCell(CreateCellCommand(cellID: ids.top, name: "TOP", makeTop: true)),
                .createCell(CreateCellCommand(cellID: ids.child, name: "UNIT")),
                .addInstance(AddInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    referencedCellID: ids.child,
                    name: "XU",
                    transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 0))
                )),
                .rotateInstance(RotateInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    deltaDegrees: 90,
                    pivot: .zero
                )),
            ]
        )

        let document = try run(request, root: root)
        let top = try #require(document.cell(withID: ids.top))
        let instance = try #require(top.instances.first { $0.id == ids.instance })

        assertPoint(instance.transform.translation, x: 0, y: 10)
        #expect(instance.transform.rotationDegrees == 90)
    }

    @Test("Mirror instance supports explicit axis origin")
    func mirrorInstanceSupportsExplicitAxisOrigin() throws {
        let ids = TestIDs(prefix: "21000000")
        let root = try temporaryRoot("mirror-origin")
        let request = LayoutCommandRequest(
            documentID: ids.document,
            outputDocumentPath: "layout.json",
            commands: [
                .createCell(CreateCellCommand(cellID: ids.top, name: "TOP", makeTop: true)),
                .createCell(CreateCellCommand(cellID: ids.child, name: "UNIT")),
                .addInstance(AddInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    referencedCellID: ids.child,
                    name: "XU",
                    transform: LayoutTransform(
                        translation: LayoutPoint(x: 3, y: 4),
                        rotationDegrees: 30
                    )
                )),
                .mirrorInstance(MirrorInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    axis: .vertical,
                    origin: LayoutPoint(x: 1, y: 0)
                )),
            ]
        )

        let document = try run(request, root: root)
        let top = try #require(document.cell(withID: ids.top))
        let instance = try #require(top.instances.first { $0.id == ids.instance })

        assertPoint(instance.transform.translation, x: -1, y: 4)
        #expect(instance.transform.rotationDegrees == 330)
        #expect(instance.transform.mirrorX)
        #expect(!instance.transform.mirrorY)
    }

    @Test("Flatten instance materializes hierarchy with deterministic IDs")
    func flattenInstanceMaterializesHierarchyWithDeterministicIDs() throws {
        let ids = TestIDs(prefix: "22000000")
        let firstRoot = try temporaryRoot("flatten-first")
        let secondRoot = try temporaryRoot("flatten-second")
        let request = flattenRequest(ids: ids, outputDocumentPath: "layout.json")

        let first = try run(request, root: firstRoot)
        let second = try run(request, root: secondRoot)
        let firstTop = try #require(first.cell(withID: ids.top))
        let secondTop = try #require(second.cell(withID: ids.top))

        #expect(firstTop.instances.isEmpty)
        #expect(firstTop.shapes.count == 2)
        #expect(first.cell(withID: ids.child) != nil)
        #expect(first.cell(withID: ids.grandchild) != nil)
        #expect(firstTop.shapes.map(\.id) == secondTop.shapes.map(\.id))
        #expect(firstTop.shapes.contains { $0.id == ids.shape } == false)
        #expect(firstTop.shapes.contains { $0.id == ids.grandchildShape } == false)

        let boxes = firstTop.shapes
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
            .sorted { $0.minX < $1.minX }
        assertRect(boxes[0], x: 10, y: 0, width: 2, height: 1)
        assertRect(boxes[1], x: 13, y: 1, width: 1, height: 1)
    }

    @Test("Flatten instance propagates nested terminal bindings")
    func flattenInstancePropagatesNestedTerminalBindings() throws {
        let ids = TestIDs(prefix: "26000000")
        let topNet = ids.uuid(30)
        let childLocalNet = ids.uuid(31)
        let leafLocalNet = ids.uuid(32)
        let leafShape = ids.uuid(33)
        let leafPin = ids.uuid(34)
        let childPin = ids.uuid(35)
        let root = try temporaryRoot("flatten-terminal-bindings")

        let leaf = LayoutCell(
            id: ids.grandchild,
            name: "LEAF",
            shapes: [
                LayoutShape(
                    id: leafShape,
                    layer: ids.layer,
                    netID: leafLocalNet,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
                ),
            ],
            pins: [
                LayoutPin(
                    id: leafPin,
                    name: "G",
                    position: .zero,
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: ids.layer,
                    netID: leafLocalNet
                ),
            ]
        )
        let child = LayoutCell(
            id: ids.child,
            name: "CHILD",
            pins: [
                LayoutPin(
                    id: childPin,
                    name: "A",
                    position: .zero,
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: ids.layer,
                    netID: childLocalNet
                ),
            ],
            instances: [
                LayoutInstance(
                    id: ids.grandchildInstance,
                    cellID: ids.grandchild,
                    name: "XL",
                    terminalNetIDs: ["G": childLocalNet]
                ),
            ]
        )
        let top = LayoutCell(
            id: ids.top,
            name: "TOP",
            instances: [
                LayoutInstance(
                    id: ids.instance,
                    cellID: ids.child,
                    name: "XC",
                    terminalNetIDs: ["A": topNet]
                ),
            ],
            nets: [LayoutNet(id: topNet, name: "TOP_NET")]
        )
        let document = LayoutDocument(id: ids.document, name: "nested-bindings", cells: [leaf, child, top], topCellID: top.id)
        let inputURL = root.appendingPathComponent("input.json")
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "layout.json",
            commands: [
                .flattenInstance(FlattenInstanceCommand(cellID: ids.top, instanceID: ids.instance)),
            ]
        )

        let flattened = try run(request, root: root)
        let flattenedTop = try #require(flattened.cell(withID: ids.top))
        #expect(flattenedTop.instances.isEmpty)
        #expect(flattenedTop.shapes.map(\.netID) == [topNet])
        #expect(flattenedTop.pins.count == 2)
        #expect(flattenedTop.pins.allSatisfy { $0.netID == topNet })
    }

    @Test("Flatten instance maps terminal-bound net IDs across repeated geometry")
    func flattenInstanceMapsTerminalBoundNetIDsAcrossRepeatedGeometry() throws {
        let ids = TestIDs(prefix: "27000000")
        let localNet = ids.uuid(40)
        let topNet = ids.uuid(41)
        let root = try temporaryRoot("flatten-repeated-net-bindings")
        let child = LayoutCell(
            id: ids.child,
            name: "UNIT",
            shapes: [
                LayoutShape(
                    id: ids.shape,
                    layer: ids.layer,
                    netID: localNet,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
                ),
            ],
            vias: [
                LayoutVia(
                    id: ids.uuid(42),
                    viaDefinitionID: "VIA1",
                    position: LayoutPoint(x: 0.5, y: 0.5),
                    netID: localNet
                ),
            ],
            labels: [
                LayoutLabel(
                    id: ids.uuid(43),
                    text: "A",
                    position: LayoutPoint(x: 0.25, y: 0.25),
                    layer: ids.layer,
                    netID: localNet
                ),
            ],
            pins: [
                LayoutPin(
                    id: ids.uuid(44),
                    name: "A",
                    position: .zero,
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: ids.layer,
                    netID: localNet
                ),
            ]
        )
        let top = LayoutCell(
            id: ids.top,
            name: "TOP",
            instances: [
                LayoutInstance(
                    id: ids.instance,
                    cellID: ids.child,
                    name: "XA",
                    transform: LayoutTransform(translation: LayoutPoint(x: 5, y: 0)),
                    terminalNetIDs: ["A": topNet],
                    repetition: LayoutRepetition(
                        columns: 2,
                        rows: 1,
                        columnStep: LayoutPoint(x: 3, y: 0),
                        rowStep: LayoutPoint(x: 0, y: 1)
                    )
                ),
            ],
            nets: [LayoutNet(id: topNet, name: "TOP_A")]
        )
        let document = LayoutDocument(id: ids.document, name: "repeated-bindings", cells: [child, top], topCellID: top.id)
        let inputURL = root.appendingPathComponent("input.json")
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "layout.json",
            commands: [
                .flattenInstance(FlattenInstanceCommand(cellID: ids.top, instanceID: ids.instance)),
            ]
        )

        let flattened = try run(request, root: root)
        let flattenedTop = try #require(flattened.cell(withID: ids.top))
        #expect(flattenedTop.instances.isEmpty)
        #expect(flattenedTop.shapes.count == 2)
        #expect(flattenedTop.vias.count == 2)
        #expect(flattenedTop.labels.count == 2)
        #expect(flattenedTop.pins.count == 2)
        #expect(flattenedTop.shapes.allSatisfy { $0.netID == topNet })
        #expect(flattenedTop.vias.allSatisfy { $0.netID == topNet })
        #expect(flattenedTop.labels.allSatisfy { $0.netID == topNet })
        #expect(flattenedTop.pins.allSatisfy { $0.netID == topNet })

        let origins = flattenedTop.shapes
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry).origin }
            .sorted { $0.x < $1.x }
        assertPoint(origins[0], x: 5, y: 0)
        assertPoint(origins[1], x: 8, y: 0)
    }

    @Test("Flatten instance leaves ambiguous local nets unbound")
    func flattenInstanceLeavesAmbiguousLocalNetsUnbound() throws {
        let ids = TestIDs(prefix: "28000000")
        let localNet = ids.uuid(50)
        let firstTopNet = ids.uuid(51)
        let secondTopNet = ids.uuid(52)
        let root = try temporaryRoot("flatten-ambiguous-net-bindings")
        let child = LayoutCell(
            id: ids.child,
            name: "AMBIGUOUS",
            shapes: [
                LayoutShape(
                    id: ids.shape,
                    layer: ids.layer,
                    netID: localNet,
                    geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1)))
                ),
            ],
            labels: [
                LayoutLabel(
                    id: ids.uuid(53),
                    text: "LOCAL",
                    position: .zero,
                    layer: ids.layer,
                    netID: localNet
                ),
            ],
            pins: [
                LayoutPin(
                    id: ids.uuid(54),
                    name: "A",
                    position: .zero,
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: ids.layer,
                    netID: localNet
                ),
                LayoutPin(
                    id: ids.uuid(55),
                    name: "B",
                    position: LayoutPoint(x: 1, y: 0),
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: ids.layer,
                    netID: localNet
                ),
            ]
        )
        let top = LayoutCell(
            id: ids.top,
            name: "TOP",
            instances: [
                LayoutInstance(
                    id: ids.instance,
                    cellID: ids.child,
                    name: "XA",
                    terminalNetIDs: [
                        "A": firstTopNet,
                        "B": secondTopNet,
                    ]
                ),
            ],
            nets: [
                LayoutNet(id: firstTopNet, name: "TOP_A"),
                LayoutNet(id: secondTopNet, name: "TOP_B"),
            ]
        )
        let document = LayoutDocument(id: ids.document, name: "ambiguous-bindings", cells: [child, top], topCellID: top.id)
        let inputURL = root.appendingPathComponent("input.json")
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "layout.json",
            commands: [
                .flattenInstance(FlattenInstanceCommand(cellID: ids.top, instanceID: ids.instance)),
            ]
        )

        let flattened = try run(request, root: root)
        let flattenedTop = try #require(flattened.cell(withID: ids.top))
        #expect(flattenedTop.shapes.map(\.netID) == [localNet])
        #expect(flattenedTop.labels.map(\.netID) == [localNet])
        #expect(Set(flattenedTop.pins.compactMap(\.netID)) == [firstTopNet, secondTopNet])
    }

    @Test("Make cell extracts selected shapes and instances")
    func makeCellExtractsSelectedShapesAndInstances() throws {
        let ids = TestIDs(prefix: "23000000")
        let root = try temporaryRoot("make-cell")
        let keptShape = ids.uuid(20)
        let groupedShape = ids.uuid(21)
        let newCell = ids.uuid(22)
        let newInstance = ids.uuid(23)
        let request = LayoutCommandRequest(
            documentID: ids.document,
            outputDocumentPath: "layout.json",
            commands: [
                .createCell(CreateCellCommand(cellID: ids.top, name: "TOP", makeTop: true)),
                .createCell(CreateCellCommand(cellID: ids.child, name: "UNIT")),
                .addRect(AddRectCommand(
                    cellID: ids.top,
                    shapeID: keptShape,
                    layer: ids.layer,
                    origin: .zero,
                    size: LayoutSize(width: 1, height: 1)
                )),
                .addRect(AddRectCommand(
                    cellID: ids.top,
                    shapeID: groupedShape,
                    layer: ids.layer,
                    origin: LayoutPoint(x: 4, y: 0),
                    size: LayoutSize(width: 2, height: 1)
                )),
                .addInstance(AddInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    referencedCellID: ids.child,
                    name: "XU",
                    transform: LayoutTransform(translation: LayoutPoint(x: 8, y: 0))
                )),
                .makeCell(MakeCellCommand(
                    cellID: ids.top,
                    newCellID: newCell,
                    newInstanceID: newInstance,
                    name: "GROUP",
                    instanceName: "XGROUP",
                    shapeIDs: [groupedShape],
                    instanceIDs: [ids.instance]
                )),
            ]
        )

        let document = try run(request, root: root)
        let top = try #require(document.cell(withID: ids.top))
        let group = try #require(document.cell(withID: newCell))
        let replacement = try #require(top.instances.first { $0.id == newInstance })

        #expect(top.shapes.map(\.id) == [keptShape])
        #expect(top.instances.count == 1)
        #expect(replacement.cellID == newCell)
        #expect(replacement.name == "XGROUP")
        #expect(group.shapes.map(\.id) == [groupedShape])
        #expect(group.instances.map(\.id) == [ids.instance])
        #expect(group.instances.first?.cellID == ids.child)
    }

    @Test("Make cell rejects invalid selections")
    func makeCellRejectsInvalidSelections() throws {
        let ids = TestIDs(prefix: "24000000")
        let missingShape = ids.uuid(30)
        let newCell = ids.uuid(31)
        let newInstance = ids.uuid(32)
        let root = try temporaryRoot("make-cell-invalid")
        let request = LayoutCommandRequest(
            documentID: ids.document,
            outputDocumentPath: "layout.json",
            commands: [
                .createCell(CreateCellCommand(cellID: ids.top, name: "TOP", makeTop: true)),
                .makeCell(MakeCellCommand(
                    cellID: ids.top,
                    newCellID: newCell,
                    newInstanceID: newInstance,
                    name: "GROUP",
                    shapeIDs: [missingShape]
                )),
            ]
        )

        #expect(throws: LayoutCommandError.shapeNotFound(missingShape)) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
    }

    @Test("Hierarchy commands reject cyclic input")
    func hierarchyCommandsRejectCyclicInput() throws {
        let ids = TestIDs(prefix: "25000000")
        let newCell = ids.uuid(40)
        let newInstance = ids.uuid(41)
        let backReference = ids.uuid(42)
        let cyclicChild = LayoutCell(
            id: ids.child,
            name: "CHILD",
            instances: [
                LayoutInstance(id: backReference, cellID: ids.top, name: "XBACK"),
            ]
        )
        let selected = LayoutInstance(id: ids.instance, cellID: ids.child, name: "XCHILD")
        let top = LayoutCell(id: ids.top, name: "TOP", instances: [selected])
        let document = LayoutDocument(id: ids.document, name: "cyclic", cells: [top, cyclicChild], topCellID: ids.top)
        let root = try temporaryRoot("cycle")
        let inputURL = root.appendingPathComponent("input.json")
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let makeCellRequest = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "make-cell.json",
            commands: [
                .makeCell(MakeCellCommand(
                    cellID: ids.top,
                    newCellID: newCell,
                    newInstanceID: newInstance,
                    name: "GROUP",
                    instanceIDs: [ids.instance]
                )),
            ]
        )
        assertInvalidHierarchyThrown {
            _ = try LayoutCommandRunner().run(request: makeCellRequest, baseURL: root)
        }

        let flattenRequest = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "flatten.json",
            commands: [
                .flattenInstance(FlattenInstanceCommand(cellID: ids.top, instanceID: ids.instance)),
            ]
        )
        assertInvalidHierarchyThrown {
            _ = try LayoutCommandRunner().run(request: flattenRequest, baseURL: root)
        }
    }

    private func flattenRequest(ids: TestIDs, outputDocumentPath: String) -> LayoutCommandRequest {
        LayoutCommandRequest(
            documentID: ids.document,
            outputDocumentPath: outputDocumentPath,
            commands: [
                .createCell(CreateCellCommand(cellID: ids.top, name: "TOP", makeTop: true)),
                .createCell(CreateCellCommand(cellID: ids.child, name: "CHILD")),
                .createCell(CreateCellCommand(cellID: ids.grandchild, name: "LEAF")),
                .addRect(AddRectCommand(
                    cellID: ids.child,
                    shapeID: ids.shape,
                    layer: ids.layer,
                    origin: .zero,
                    size: LayoutSize(width: 2, height: 1)
                )),
                .addRect(AddRectCommand(
                    cellID: ids.grandchild,
                    shapeID: ids.grandchildShape,
                    layer: ids.layer,
                    origin: LayoutPoint(x: 1, y: 1),
                    size: LayoutSize(width: 1, height: 1)
                )),
                .addInstance(AddInstanceCommand(
                    cellID: ids.child,
                    instanceID: ids.grandchildInstance,
                    referencedCellID: ids.grandchild,
                    name: "XL",
                    transform: LayoutTransform(translation: LayoutPoint(x: 2, y: 0))
                )),
                .addInstance(AddInstanceCommand(
                    cellID: ids.top,
                    instanceID: ids.instance,
                    referencedCellID: ids.child,
                    name: "XC",
                    transform: LayoutTransform(translation: LayoutPoint(x: 10, y: 0))
                )),
                .flattenInstance(FlattenInstanceCommand(cellID: ids.top, instanceID: ids.instance)),
            ]
        )
    }

    private func run(_ request: LayoutCommandRequest, root: URL) throws -> LayoutDocument {
        _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        let outputURL = root.appendingPathComponent(request.outputDocumentPath)
        return try serializer.decodeDocument(Data(contentsOf: outputURL))
    }

    private func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutHierarchyCommandTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertPoint(_ point: LayoutPoint, x: Double, y: Double) {
        #expect(abs(point.x - x) < 1e-9)
        #expect(abs(point.y - y) < 1e-9)
    }

    private func assertRect(_ rect: LayoutRect, x: Double, y: Double, width: Double, height: Double) {
        #expect(abs(rect.origin.x - x) < 1e-9)
        #expect(abs(rect.origin.y - y) < 1e-9)
        #expect(abs(rect.size.width - width) < 1e-9)
        #expect(abs(rect.size.height - height) < 1e-9)
    }

    private func assertInvalidHierarchyThrown(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected invalid hierarchy error")
        } catch let error as LayoutCommandError {
            guard case .invalidInstanceHierarchy = error else {
                Issue.record("Expected invalid hierarchy error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected layout command error, got \(error)")
        }
    }
}

private struct TestIDs {
    let prefix: String
    let layer = LayoutLayerID(name: "M1", purpose: "drawing")

    var document: UUID { uuid(0) }
    var top: UUID { uuid(1) }
    var child: UUID { uuid(2) }
    var grandchild: UUID { uuid(3) }
    var shape: UUID { uuid(4) }
    var grandchildShape: UUID { uuid(5) }
    var instance: UUID { uuid(6) }
    var grandchildInstance: UUID { uuid(7) }

    func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: "\(prefix)-0000-0000-0000-\(String(format: "%012d", suffix))")!
    }
}
