import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import Testing

@Suite("Layout command runner")
struct LayoutCommandRunnerTests {
    private let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let cellID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let netID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let shapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let labelID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    private let viaID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    private let temporaryShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    private let firstSplitShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    private let secondSplitShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    private let childCellID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let instanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    private func makeTemporaryRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Runner applies replayable commands and writes artifacts")
    func runnerAppliesReplayableCommandsAndWritesArtifacts() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let request = replayableCommandRequest(layer: layer)

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        expectReplayableSummary(result, request: request)
        let documentData = try expectReplayedDocument(root: root, result: result)
        try expectReplayArtifacts(root: root, result: result, documentData: documentData)
    }

    private func replayableCommandRequest(layer: LayoutLayerID) -> LayoutCommandRequest {
        LayoutCommandRequest(
            documentID: documentID,
            documentName: "agent-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: replayableCommands(layer: layer)
        )
    }

    private func replayableCommands(layer: LayoutLayerID) -> [LayoutCommand] {
        [
            .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
            .createCell(CreateCellCommand(cellID: childCellID, name: "device")),
            .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "out")),
            .addInstance(AddInstanceCommand(
                cellID: cellID,
                instanceID: instanceID,
                referencedCellID: childCellID,
                name: "u_device",
                transform: LayoutTransform(translation: LayoutPoint(x: 20, y: 30))
            )),
            .moveInstance(MoveInstanceCommand(
                cellID: cellID,
                instanceID: instanceID,
                delta: LayoutPoint(x: 5, y: -10)
            )),
            .rotateInstance(RotateInstanceCommand(cellID: cellID, instanceID: instanceID, deltaDegrees: 90)),
            .mirrorInstance(MirrorInstanceCommand(cellID: cellID, instanceID: instanceID, axis: .x)),
            .addRect(AddRectCommand(
                cellID: cellID,
                shapeID: shapeID,
                layer: layer,
                origin: LayoutPoint(x: 1, y: 2),
                size: LayoutSize(width: 3, height: 4),
                netID: netID,
                properties: ["role": "wire"]
            )),
            .translateShape(TranslateShapeCommand(
                cellID: cellID,
                shapeID: shapeID,
                delta: LayoutPoint(x: 10, y: 0)
            )),
            .resizeShape(ResizeShapeCommand(
                cellID: cellID,
                shapeID: shapeID,
                deltaMinX: 0,
                deltaMinY: 0,
                deltaMaxX: 2,
                deltaMaxY: 1
            )),
            .splitShape(SplitShapeCommand(
                cellID: cellID,
                shapeID: shapeID,
                firstShapeID: firstSplitShapeID,
                secondShapeID: secondSplitShapeID,
                axis: .vertical,
                coordinate: 13
            )),
            .addRect(AddRectCommand(
                cellID: cellID,
                shapeID: temporaryShapeID,
                layer: layer,
                origin: LayoutPoint(x: 50, y: 50),
                size: LayoutSize(width: 1, height: 1),
                netID: nil,
                properties: ["role": "temporary-fill"]
            )),
            .deleteShape(DeleteShapeCommand(cellID: cellID, shapeID: temporaryShapeID)),
            .addLabel(AddLabelCommand(
                cellID: cellID,
                labelID: labelID,
                text: "out",
                position: LayoutPoint(x: 11, y: 2),
                layer: layer,
                netID: netID
            )),
            .addVia(AddViaCommand(
                cellID: cellID,
                viaID: viaID,
                viaDefinitionID: "via1",
                position: LayoutPoint(x: 12, y: 3),
                netID: netID
            )),
            .addConstraint(AddConstraintCommand(
                cellID: cellID,
                constraint: .alignment(LayoutAlignmentConstraint(
                    mode: .minY,
                    members: [firstSplitShapeID, secondSplitShapeID]
                ))
            )),
        ]
    }

    private func expectReplayableSummary(_ result: LayoutCommandResult, request: LayoutCommandRequest) {
        #expect(result.status == "passed")
        #expect(result.commandCount == 16)
        #expect(result.cellCount == 2)
        #expect(result.shapeCount == 2)
        #expect(result.labelCount == 1)
        #expect(result.viaCount == 1)
        #expect(result.netCount == 1)
        #expect(result.appliedCommands.map(\.index) == Array(0..<request.commands.count))
        #expect(result.appliedCommands.map(\.kind) == request.commands.map(\.kind))
        #expect(result.appliedCommands.first == LayoutAppliedCommand(
            index: 0,
            kind: .createCell,
            cellID: cellID,
            entityID: cellID
        ))
        #expect(result.appliedCommands.last == LayoutAppliedCommand(
            index: 15,
            kind: .addConstraint,
            cellID: cellID,
            entityID: nil
        ))
    }

    @Test("Runner rejects artifact path collisions before writing output")
    func runnerRejectsArtifactPathCollisionsBeforeWritingOutput() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerPathCollision")
        let layoutPath = "artifacts/layout.json"
        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "collision-layout",
            outputDocumentPath: layoutPath,
            artifactManifestPath: layoutPath,
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
            ]
        )
        let layoutURL = root.appendingPathComponent(layoutPath)

        #expect(throws: LayoutCommandError.conflictingArtifactPath("output and artifact-manifest", layoutURL.path)) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: layoutURL.path))
    }

    private func expectReplayedDocument(root: URL, result: LayoutCommandResult) throws -> Data {
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let documentData = try Data(contentsOf: documentURL)
        #expect(LayoutCommandRunner.sha256Hex(documentData) == result.outputDocumentSHA256)
        let document = try LayoutDocumentSerializer().decodeDocument(documentData)
        #expect(document.id == documentID)
        #expect(document.topCellID == cellID)
        let cell = try #require(document.cell(withID: cellID))
        try expectReplayedInstance(in: cell)
        try expectReplayedGeometry(in: cell)
        try expectReplayedConstraints(in: cell)
        return documentData
    }

    private func expectReplayedInstance(in cell: LayoutCell) throws {
        let instance = try #require(cell.instances.first { $0.id == instanceID })
        #expect(instance.cellID == childCellID)
        #expect(instance.name == "u_device")
        #expect(instance.transform.translation == LayoutPoint(x: 25, y: 20))
        #expect(instance.transform.rotationDegrees == 90)
        #expect(instance.transform.mirrorX)
        #expect(instance.transform.mirrorY == false)
    }

    private func expectReplayedGeometry(in cell: LayoutCell) throws {
        let firstSplit = try #require(cell.shapes.first { $0.id == firstSplitShapeID })
        let secondSplit = try #require(cell.shapes.first { $0.id == secondSplitShapeID })
        #expect(firstSplit.netID == netID)
        #expect(secondSplit.netID == netID)
        #expect(cell.shapes.contains { $0.id == shapeID } == false)
        #expect(cell.labels.map(\.id) == [labelID])
        #expect(cell.labels.first?.text == "out")
        expectRect(firstSplit, origin: LayoutPoint(x: 11, y: 2), size: LayoutSize(width: 2, height: 5))
        expectRect(secondSplit, origin: LayoutPoint(x: 13, y: 2), size: LayoutSize(width: 3, height: 5))
    }

    private func expectReplayedConstraints(in cell: LayoutCell) throws {
        let constraint = try #require(cell.constraints.first)
        guard case .alignment(let alignment) = constraint else {
            Issue.record("Expected alignment constraint")
            return
        }
        #expect(cell.constraints.count == 1)
        #expect(alignment.mode == .minY)
        #expect(alignment.members == [firstSplitShapeID, secondSplitShapeID])
    }

    private func expectRect(_ shape: LayoutShape, origin: LayoutPoint, size: LayoutSize) {
        if case .rect(let rect) = shape.geometry {
            #expect(rect.origin == origin)
            #expect(rect.size == size)
        } else {
            Issue.record("Expected rectangle geometry")
        }
    }

    private func expectReplayArtifacts(
        root: URL,
        result: LayoutCommandResult,
        documentData: Data
    ) throws {
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let manifestURL = root.appendingPathComponent("artifacts/manifest.json")
        let resultURL = root.appendingPathComponent("artifacts/result.json")
        #expect(FileManager.default.fileExists(atPath: documentURL.path))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        let manifest = try JSONDecoder().decode(LayoutCommandArtifactManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.artifacts.count == 2)
        let artifact = try #require(manifest.artifacts.first { $0.id == "output-layout-document" })
        #expect(artifact.kind == "layout")
        #expect(artifact.format == "LayoutDocumentJSON")
        #expect(artifact.path == documentURL.path)
        #expect(artifact.sha256 == result.outputDocumentSHA256)
        #expect(artifact.byteCount == documentData.count)
        let savedResult = try JSONDecoder().decode(LayoutCommandResult.self, from: Data(contentsOf: resultURL))
        #expect(savedResult == result)
        let resultData = try Data(contentsOf: resultURL)
        let resultArtifact = try #require(manifest.artifacts.first { $0.id == "layout-command-result" })
        #expect(resultArtifact.kind == "result")
        #expect(resultArtifact.format == "LayoutCommandResultJSON")
        #expect(resultArtifact.path == resultURL.path)
        #expect(resultArtifact.sha256 == LayoutCommandRunner.sha256Hex(resultData))
        #expect(resultArtifact.byteCount == resultData.count)
    }

    @Test("Runner creates generic polygon and path shapes")
    func runnerCreatesGenericPolygonAndPathShapes() throws {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let polygonShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let pathShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let geometry = genericShapeGeometry()
        let request = genericShapeRequest(
            layer: layer,
            polygonShapeID: polygonShapeID,
            pathShapeID: pathShapeID,
            geometry: geometry
        )
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        try expectGenericShapeResult(
            result,
            root: root,
            request: request,
            polygonShapeID: polygonShapeID,
            pathShapeID: pathShapeID,
            geometry: geometry
        )
    }

    private struct GenericShapeGeometry {
        let polygon: LayoutPolygon
        let path: LayoutPath
    }

    private func genericShapeGeometry() -> GenericShapeGeometry {
        GenericShapeGeometry(
            polygon: LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 4, y: 0),
                LayoutPoint(x: 4, y: 2),
                LayoutPoint(x: 1, y: 3),
                LayoutPoint(x: 0, y: 2),
            ]),
            path: LayoutPath(
                points: [
                    LayoutPoint(x: 6, y: 1),
                    LayoutPoint(x: 8, y: 1),
                    LayoutPoint(x: 8, y: 4),
                ],
                width: 0.5,
                endCap: .round
            )
        )
    }

    private func genericShapeRequest(
        layer: LayoutLayerID,
        polygonShapeID: UUID,
        pathShapeID: UUID,
        geometry: GenericShapeGeometry
    ) -> LayoutCommandRequest {
        LayoutCommandRequest(
            documentID: documentID,
            documentName: "generic-shape-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
                .addShape(AddShapeCommand(
                    cellID: cellID,
                    shapeID: polygonShapeID,
                    layer: layer,
                    geometry: .polygon(geometry.polygon),
                    netID: netID,
                    properties: ["intent": "device-boundary"]
                )),
                .addShape(AddShapeCommand(
                    cellID: cellID,
                    shapeID: pathShapeID,
                    layer: layer,
                    geometry: .path(geometry.path),
                    netID: netID,
                    properties: ["intent": "route"]
                )),
            ]
        )
    }

    private func expectGenericShapeResult(
        _ result: LayoutCommandResult,
        root: URL,
        request: LayoutCommandRequest,
        polygonShapeID: UUID,
        pathShapeID: UUID,
        geometry: GenericShapeGeometry
    ) throws {
        #expect(result.status == "passed")
        #expect(result.commandCount == 4)
        #expect(result.shapeCount == 2)
        #expect(result.netCount == 1)
        #expect(result.appliedCommands.map(\.kind) == request.commands.map(\.kind))

        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let document = try LayoutDocumentSerializer().decodeDocument(Data(contentsOf: documentURL))
        let cell = try #require(document.cell(withID: cellID))
        let savedPolygon = try #require(cell.shapes.first { $0.id == polygonShapeID })
        let savedPath = try #require(cell.shapes.first { $0.id == pathShapeID })
        #expect(savedPolygon.netID == netID)
        #expect(savedPath.netID == netID)
        #expect(savedPolygon.properties["intent"] == "device-boundary")
        #expect(savedPath.properties["intent"] == "route")
        #expect(savedPolygon.geometry == .polygon(geometry.polygon))
        #expect(savedPath.geometry == .path(geometry.path))
    }

    @Test("Runner rejects invalid generic shape geometry before writing artifacts")
    func runnerRejectsInvalidGenericShapeGeometryBeforeWritingArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "invalid-generic-shape-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addShape(AddShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .polygon(LayoutPolygon(points: [
                        LayoutPoint(x: 0, y: 0),
                        LayoutPoint(x: 1, y: 0),
                    ]))
                )),
            ]
        )

        #expect(throws: LayoutCommandError.invalidShapeGeometry(kind: "polygon")) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
    }

    @Test("Runner rejects dangling net references before writing artifacts")
    func runnerRejectsDanglingNetReferencesBeforeWritingArtifacts() throws {
        let missingNetID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let commands: [LayoutCommand] = [
            .addRect(AddRectCommand(
                cellID: cellID,
                shapeID: shapeID,
                layer: layer,
                origin: .zero,
                size: LayoutSize(width: 1, height: 1),
                netID: missingNetID
            )),
            .addShape(AddShapeCommand(
                cellID: cellID,
                shapeID: shapeID,
                layer: layer,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 1))),
                netID: missingNetID
            )),
            .addLabel(AddLabelCommand(
                cellID: cellID,
                labelID: labelID,
                text: "missing",
                position: .zero,
                layer: layer,
                netID: missingNetID
            )),
            .addVia(AddViaCommand(
                cellID: cellID,
                viaID: viaID,
                viaDefinitionID: "via1",
                position: .zero,
                netID: missingNetID
            )),
            .addInstance(AddInstanceCommand(
                cellID: cellID,
                instanceID: instanceID,
                referencedCellID: childCellID,
                name: "u_child",
                terminalNetIDs: ["A": missingNetID]
            )),
        ]

        for command in commands {
            let root = try makeTemporaryRoot(prefix: "LayoutCommandDanglingNetTests")
            let request = danglingNetRequest(command: command)
            #expect(throws: LayoutCommandError.netNotFound(missingNetID)) {
                _ = try LayoutCommandRunner().run(request: request, baseURL: root)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
        }
    }

    private func danglingNetRequest(command: LayoutCommand) -> LayoutCommandRequest {
        var commands: [LayoutCommand] = [
            .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
        ]
        if case .addInstance = command {
            commands.append(.createCell(CreateCellCommand(cellID: childCellID, name: "child")))
        }
        commands.append(command)
        return LayoutCommandRequest(
            documentID: documentID,
            documentName: "dangling-net-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: commands
        )
    }

    @Test("Runner fixes repairable DRC violations and writes a sweep report artifact")
    func runnerFixesRepairableDRCViolationsAndWritesSweepReportArtifact() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRepairTests")
        let fixture = try writeRepairFixture(root: root)
        let request = repairCommandRequest()

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        expectRepairCommandResult(result)
        try expectRepairedDocument(root: root, fixture: fixture)
        try expectRepairReportArtifact(root: root)
    }

    @Test("Runner rejects pending artifact collisions before writing output")
    func runnerRejectsPendingArtifactCollisionsBeforeWritingOutput() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandPendingPathCollision")
        _ = try writeRepairFixture(root: root)
        let layoutPath = "artifacts/layout.json"
        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: layoutPath,
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .fixAllViolations(FixAllViolationsCommand(
                    cellID: cellID,
                    technologyPath: "tech.json",
                    reportPath: layoutPath,
                    budget: 16
                )),
            ]
        )
        let layoutURL = root.appendingPathComponent(layoutPath)

        #expect(throws: LayoutCommandError.conflictingArtifactPath(
            "output and pending-artifact:layout-repair-sweep-0",
            layoutURL.path
        )) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: layoutURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
    }

    @Test("CLI service exits nonzero when command result is non-passed")
    func cliServiceExitsNonzeroWhenCommandResultIsNonPassed() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRepairCLITests")
        _ = try writeRepairFixture(root: root)
        let requestURL = root.appendingPathComponent("request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(repairCommandRequest()).write(to: requestURL, options: [.atomic])

        let response = try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: ["--request", requestURL.path, "--json"])
        )
        let resultData = try #require(response.output.data(using: .utf8))
        let result = try JSONDecoder().decode(LayoutCommandResult.self, from: resultData)

        #expect(response.exitCode == 1)
        #expect(result.status == "partial")
    }

    private struct RepairFixture {
        let tech: LayoutTechDatabase
        let serializer: LayoutDocumentSerializer
    }

    private func writeRepairFixture(root: URL) throws -> RepairFixture {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let tech = Self.makeRepairTech(layer: layer)
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(repairDocument(layer: layer))
            .write(to: root.appendingPathComponent("input.json"), options: [.atomic])
        try serializer.encodeTech(tech)
            .write(to: root.appendingPathComponent("tech.json"), options: [.atomic])
        return RepairFixture(tech: tech, serializer: serializer)
    }

    private func repairDocument(layer: LayoutLayerID) -> LayoutDocument {
        LayoutDocument(
            id: documentID,
            name: "repair-layout",
            cells: [
                LayoutCell(
                    id: cellID,
                    name: "top",
                    shapes: repairShapes(layer: layer)
                ),
            ],
            topCellID: cellID
        )
    }

    private func repairShapes(layer: LayoutLayerID) -> [LayoutShape] {
        let netA = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let netB = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let openNet = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        return [
            repairRect("00000000-0000-0000-0000-000000000201", layer, netA, .zero, width: 1, height: 0.4),
            repairRect("00000000-0000-0000-0000-000000000202", layer, netB, LayoutPoint(x: 1.1, y: 0), width: 1, height: 0.4),
            repairRect("00000000-0000-0000-0000-000000000203", layer, nil, LayoutPoint(x: 0, y: 5), width: 0.1, height: 1),
            repairRect("00000000-0000-0000-0000-000000000204", layer, netA, LayoutPoint(x: 10, y: 10), width: 1, height: 0.4),
            repairRect("00000000-0000-0000-0000-000000000205", layer, netB, LayoutPoint(x: 10.5, y: 10), width: 1, height: 0.4),
            repairRect("00000000-0000-0000-0000-000000000206", layer, openNet, LayoutPoint(x: 20, y: 20), width: 1, height: 0.4),
            repairRect("00000000-0000-0000-0000-000000000207", layer, openNet, LayoutPoint(x: 25, y: 20), width: 1, height: 0.4),
        ]
    }

    private func repairRect(
        _ rawID: String,
        _ layer: LayoutLayerID,
        _ netID: UUID?,
        _ origin: LayoutPoint,
        width: Double,
        height: Double
    ) -> LayoutShape {
        LayoutShape(
            id: UUID(uuidString: rawID)!,
            layer: layer,
            netID: netID,
            geometry: .rect(LayoutRect(origin: origin, size: LayoutSize(width: width, height: height)))
        )
    }

    private func repairCommandRequest() -> LayoutCommandRequest {
        LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .fixAllViolations(FixAllViolationsCommand(
                    cellID: cellID,
                    technologyPath: "tech.json",
                    reportPath: "artifacts/repair-report.json",
                    budget: 16
                )),
            ]
        )
    }

    private func expectRepairCommandResult(_ result: LayoutCommandResult) {
        #expect(result.status == "partial")
        #expect(result.commandCount == 1)
        #expect(result.appliedCommands == [
            LayoutAppliedCommand(index: 0, kind: .fixAllViolations, cellID: cellID, entityID: nil),
        ])
    }

    private func expectRepairedDocument(root: URL, fixture: RepairFixture) throws {
        let repairedDocumentURL = root.appendingPathComponent("artifacts/layout.json")
        let repairedDocument = try fixture.serializer.decodeDocument(Data(contentsOf: repairedDocumentURL))
        let finalViolations = LayoutDRCService()
            .run(document: repairedDocument, tech: fixture.tech, cellID: cellID)
            .violations
        #expect(!finalViolations.contains { $0.kind == .minSpacing })
        #expect(!finalViolations.contains { $0.kind == .minWidth })
        #expect(!finalViolations.contains { $0.kind == .overlapShort })
        #expect(finalViolations.contains { $0.kind == .disconnectedOpen })
    }

    private func expectRepairReportArtifact(root: URL) throws {
        let reportURL = root.appendingPathComponent("artifacts/repair-report.json")
        let reportData = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(LayoutRepairSweepReport.self, from: reportData)
        #expect(report.status == "fixed_point_with_residuals")
        #expect(report.commandIndex == 0)
        #expect(report.cellID == cellID)
        #expect(report.budget == 16)
        #expect(report.reachedFixedPoint)
        #expect(report.appliedRepairCount >= 3)
        #expect(report.residualViolationCount >= 1)
        #expect(report.residuals.allSatisfy { $0.violation.kind == .disconnectedOpen })
        #expect(report.residuals.allSatisfy { $0.reasonCode == "unsupported_kind" })

        let manifestURL = root.appendingPathComponent("artifacts/manifest.json")
        let manifest = try JSONDecoder().decode(
            LayoutCommandArtifactManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(manifest.artifacts.count == 3)
        let repairArtifact = try #require(manifest.artifacts.first { $0.id == "layout-repair-sweep-0" })
        #expect(repairArtifact.kind == "layout-repair-sweep")
        #expect(repairArtifact.format == "LayoutRepairSweepReportJSON")
        #expect(repairArtifact.path == reportURL.path)
        #expect(repairArtifact.sha256 == LayoutCommandRunner.sha256Hex(reportData))
        #expect(repairArtifact.byteCount == reportData.count)
    }

    @Test("Runner resizes and splits polygon shapes")
    func runnerResizesAndSplitsPolygonShapes() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")
        let fixture = try writePolygonSplitFixture(root: root)
        let request = polygonSplitRequest()

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        try expectPolygonSplitResult(result, fixture: fixture)
    }

    @Test("Runner rejects concave polygon splits before writing artifacts")
    func runnerRejectsConcavePolygonSplitsBeforeWritingArtifacts() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(concavePolygonSplitDocument(layer: layer))
            .write(to: root.appendingPathComponent("input.json"), options: [.atomic])
        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            commands: [
                .splitShape(SplitShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    firstShapeID: firstSplitShapeID,
                    secondShapeID: secondSplitShapeID,
                    axis: .vertical,
                    coordinate: 2
                )),
            ]
        )

        #expect(throws: LayoutCommandError.unsupportedSplitGeometry(shapeID)) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
    }

    private struct PolygonSplitFixture {
        let outputURL: URL
        let serializer: LayoutDocumentSerializer
    }

    private func writePolygonSplitFixture(root: URL) throws -> PolygonSplitFixture {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(polygonSplitDocument(layer: layer))
            .write(to: root.appendingPathComponent("input.json"), options: [.atomic])
        return PolygonSplitFixture(
            outputURL: root.appendingPathComponent("artifacts/layout.json"),
            serializer: serializer
        )
    }

    private func polygonSplitDocument(layer: LayoutLayerID) -> LayoutDocument {
        LayoutDocument(
            id: documentID,
            name: "polygon-layout",
            cells: [
                LayoutCell(
                    id: cellID,
                    name: "top",
                    shapes: [
                        LayoutShape(
                            id: shapeID,
                            layer: layer,
                            netID: netID,
                            geometry: .polygon(testPolygon()),
                            properties: ["role": "polygon-wire"]
                        ),
                    ],
                    nets: [LayoutNet(id: netID, name: "out")]
                ),
            ],
            topCellID: cellID
        )
    }

    private func concavePolygonSplitDocument(layer: LayoutLayerID) -> LayoutDocument {
        LayoutDocument(
            id: documentID,
            name: "concave-polygon-layout",
            cells: [
                LayoutCell(
                    id: cellID,
                    name: "top",
                    shapes: [
                        LayoutShape(
                            id: shapeID,
                            layer: layer,
                            netID: netID,
                            geometry: .polygon(LayoutPolygon(points: [
                                LayoutPoint(x: 0, y: 0),
                                LayoutPoint(x: 4, y: 0),
                                LayoutPoint(x: 4, y: 4),
                                LayoutPoint(x: 3, y: 4),
                                LayoutPoint(x: 3, y: 1),
                                LayoutPoint(x: 1, y: 1),
                                LayoutPoint(x: 1, y: 4),
                                LayoutPoint(x: 0, y: 4),
                            ])),
                            properties: ["role": "concave-polygon-wire"]
                        ),
                    ],
                    nets: [LayoutNet(id: netID, name: "out")]
                ),
            ],
            topCellID: cellID
        )
    }

    private func testPolygon() -> LayoutPolygon {
        LayoutPolygon(points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 4, y: 4),
            LayoutPoint(x: 0, y: 4),
        ])
    }

    private func polygonSplitRequest() -> LayoutCommandRequest {
        LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            commands: [
                .resizeShape(ResizeShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    deltaMinX: -1,
                    deltaMinY: -2,
                    deltaMaxX: 3,
                    deltaMaxY: 4
                )),
                .splitShape(SplitShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    firstShapeID: firstSplitShapeID,
                    secondShapeID: secondSplitShapeID,
                    axis: .vertical,
                    coordinate: 3
                )),
            ]
        )
    }

    private func expectPolygonSplitResult(
        _ result: LayoutCommandResult,
        fixture: PolygonSplitFixture
    ) throws {
        #expect(result.status == "passed")
        #expect(result.commandCount == 2)
        #expect(result.shapeCount == 2)
        let outputDocument = try fixture.serializer.decodeDocument(Data(contentsOf: fixture.outputURL))
        let cell = try #require(outputDocument.cell(withID: cellID))
        #expect(cell.shapes.contains { $0.id == shapeID } == false)
        let firstSplit = try #require(cell.shapes.first { $0.id == firstSplitShapeID })
        let secondSplit = try #require(cell.shapes.first { $0.id == secondSplitShapeID })
        #expect(firstSplit.netID == netID)
        #expect(secondSplit.netID == netID)
        #expect(firstSplit.properties["splitParentShapeID"] == shapeID.uuidString)
        #expect(secondSplit.properties["splitParentShapeID"] == shapeID.uuidString)

        guard case .polygon(let firstPolygon) = firstSplit.geometry else {
            Issue.record("Expected first split polygon geometry")
            return
        }
        guard case .polygon(let secondPolygon) = secondSplit.geometry else {
            Issue.record("Expected second split polygon geometry")
            return
        }
        #expect(firstPolygon.isValid)
        #expect(secondPolygon.isValid)
        let firstBounds = LayoutGeometryAnalysis.boundingBox(for: firstSplit.geometry)
        let secondBounds = LayoutGeometryAnalysis.boundingBox(for: secondSplit.geometry)
        #expect(firstBounds == LayoutRect(
            origin: LayoutPoint(x: -1, y: -2),
            size: LayoutSize(width: 4, height: 10)
        ))
        #expect(secondBounds == LayoutRect(
            origin: LayoutPoint(x: 3, y: -2),
            size: LayoutSize(width: 4, height: 10)
        ))
    }

    @Test("Runner splits path shapes")
    func runnerSplitsPathShapes() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")
        defer { removeTemporaryRoots([root]) }
        let fixture = try writePathSplitFixture(root: root)
        let request = pathSplitRequest()

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        try expectPathSplitResult(result, fixture: fixture)
    }

    private struct PathSplitFixture {
        let outputURL: URL
        let sourcePath: LayoutPath
        let serializer: LayoutDocumentSerializer
    }

    private func writePathSplitFixture(root: URL) throws -> PathSplitFixture {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let path = testPath()
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(pathSplitDocument(layer: layer, path: path))
            .write(to: root.appendingPathComponent("input.json"), options: [.atomic])
        return PathSplitFixture(
            outputURL: root.appendingPathComponent("artifacts/layout.json"),
            sourcePath: path,
            serializer: serializer
        )
    }

    private func pathSplitDocument(layer: LayoutLayerID, path: LayoutPath) -> LayoutDocument {
        LayoutDocument(
            id: documentID,
            name: "path-layout",
            cells: [
                LayoutCell(
                    id: cellID,
                    name: "top",
                    shapes: [
                        LayoutShape(
                            id: shapeID,
                            layer: layer,
                            netID: netID,
                            geometry: .path(path),
                            properties: ["role": "path-wire"]
                        ),
                    ],
                    nets: [LayoutNet(id: netID, name: "out")]
                ),
            ],
            topCellID: cellID
        )
    }

    private func testPath() -> LayoutPath {
        LayoutPath(
            points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 4, y: 0),
                LayoutPoint(x: 4, y: 4),
            ],
            width: 0.5,
            endCap: .round
        )
    }

    private func pathSplitRequest() -> LayoutCommandRequest {
        LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            commands: [
                .splitShape(SplitShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    firstShapeID: firstSplitShapeID,
                    secondShapeID: secondSplitShapeID,
                    axis: .vertical,
                    coordinate: 2
                )),
            ]
        )
    }

    private func expectPathSplitResult(
        _ result: LayoutCommandResult,
        fixture: PathSplitFixture
    ) throws {
        #expect(result.status == "passed")
        #expect(result.commandCount == 1)
        #expect(result.shapeCount == 2)
        let outputDocument = try fixture.serializer.decodeDocument(Data(contentsOf: fixture.outputURL))
        let cell = try #require(outputDocument.cell(withID: cellID))
        #expect(cell.shapes.contains { $0.id == shapeID } == false)

        let firstSplit = try #require(cell.shapes.first { $0.id == firstSplitShapeID })
        let secondSplit = try #require(cell.shapes.first { $0.id == secondSplitShapeID })
        #expect(firstSplit.netID == netID)
        #expect(secondSplit.netID == netID)
        #expect(firstSplit.properties["splitParentShapeID"] == shapeID.uuidString)
        #expect(secondSplit.properties["splitParentShapeID"] == shapeID.uuidString)

        guard case .path(let firstPath) = firstSplit.geometry else {
            Issue.record("Expected first split path geometry")
            return
        }
        guard case .path(let secondPath) = secondSplit.geometry else {
            Issue.record("Expected second split path geometry")
            return
        }

        #expect(firstPath.points == [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 2, y: 0),
        ])
        #expect(secondPath.points == [
            LayoutPoint(x: 2, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 4, y: 4),
        ])
        #expect(firstPath.width == fixture.sourcePath.width)
        #expect(secondPath.width == fixture.sourcePath.width)
        #expect(firstPath.endCap == fixture.sourcePath.endCap)
        #expect(secondPath.endCap == fixture.sourcePath.endCap)
    }

    @Test("Runner rejects random new documents")
    func runnerRejectsRandomNewDocuments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let request = LayoutCommandRequest(
            outputDocumentPath: "layout.json",
            commands: []
        )

        #expect(throws: LayoutCommandError.missingDocumentIDForNewDocument) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
    }

    @Test("Runner rejects input document with missing top cell before writing artifacts")
    func runnerRejectsInputDocumentWithMissingTopCellBeforeWritingArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("input.json")
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let manifestURL = root.appendingPathComponent("artifacts/manifest.json")
        let resultURL = root.appendingPathComponent("artifacts/result.json")
        let missingTopCellID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let document = LayoutDocument(
            id: documentID,
            name: "invalid-missing-top",
            cells: [LayoutCell(id: cellID, name: "existing")],
            topCellID: missingTopCellID
        )
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: childCellID, name: "child"))
            ]
        )

        #expect(throws: LayoutCommandError.cellNotFound(missingTopCellID)) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: documentURL.path))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
    }

    @Test("Runner rejects input document with duplicate cell IDs before writing artifacts")
    func runnerRejectsInputDocumentWithDuplicateCellIDsBeforeWritingArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("input.json")
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let manifestURL = root.appendingPathComponent("artifacts/manifest.json")
        let resultURL = root.appendingPathComponent("artifacts/result.json")
        let document = LayoutDocument(
            id: documentID,
            name: "invalid-duplicate-cell",
            cells: [
                LayoutCell(id: cellID, name: "first"),
                LayoutCell(id: cellID, name: "second"),
            ],
            topCellID: cellID
        )
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(document).write(to: inputURL, options: [.atomic])

        let request = LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: childCellID, name: "child"))
            ]
        )

        #expect(throws: LayoutCommandError.duplicateCellID(cellID)) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: documentURL.path))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
    }

    @Test("Runner rejects cyclic instance hierarchy")
    func runnerRejectsCyclicInstanceHierarchy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let firstCellID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let secondCellID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let firstInstanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let secondInstanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let request = LayoutCommandRequest(
            documentID: documentID,
            outputDocumentPath: "layout.json",
            commands: [
                .createCell(CreateCellCommand(cellID: firstCellID, name: "a", makeTop: true)),
                .createCell(CreateCellCommand(cellID: secondCellID, name: "b")),
                .addInstance(AddInstanceCommand(
                    cellID: firstCellID,
                    instanceID: firstInstanceID,
                    referencedCellID: secondCellID,
                    name: "u_b"
                )),
                .addInstance(AddInstanceCommand(
                    cellID: secondCellID,
                    instanceID: secondInstanceID,
                    referencedCellID: firstCellID,
                    name: "u_a"
                )),
            ]
        )

        #expect(throws: LayoutCommandError.invalidInstanceHierarchy(
            parentCellID: secondCellID,
            referencedCellID: firstCellID
        )) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
    }

    @Test("Runner leaves no output artifacts when a later command fails")
    func runnerLeavesNoOutputArtifactsWhenLaterCommandFails() throws {
        let root = try makeTemporaryRoot(prefix: "LayoutCommandRunnerTests")
        let fixture = try writeRollbackFixture(root: root)
        let request = rollbackFailureRequest()

        #expect(throws: LayoutCommandError.invalidResizeResult(
            shapeID: shapeID,
            width: -1,
            height: 1
        )) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        expectNoArtifacts(fixture.artifactURLs)
        try expectInputDocumentUnchanged(fixture)
    }

    private struct RollbackFixture {
        let inputURL: URL
        let artifactURLs: [URL]
        let serializer: LayoutDocumentSerializer
    }

    private func writeRollbackFixture(root: URL) throws -> RollbackFixture {
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(rollbackDocument())
            .write(to: root.appendingPathComponent("input.json"), options: [.atomic])
        return RollbackFixture(
            inputURL: root.appendingPathComponent("input.json"),
            artifactURLs: [
                root.appendingPathComponent("artifacts/layout.json"),
                root.appendingPathComponent("artifacts/manifest.json"),
                root.appendingPathComponent("artifacts/result.json"),
            ],
            serializer: serializer
        )
    }

    private func rollbackDocument() -> LayoutDocument {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        return LayoutDocument(
            id: documentID,
            name: "existing-layout",
            cells: [
                LayoutCell(
                    id: cellID,
                    name: "top",
                    shapes: [
                        LayoutShape(
                            id: shapeID,
                            layer: layer,
                            geometry: .rect(LayoutRect(
                                origin: LayoutPoint(x: 0, y: 0),
                                size: LayoutSize(width: 2, height: 1)
                            ))
                        ),
                    ]
                ),
            ],
            topCellID: cellID
        )
    }

    private func rollbackFailureRequest() -> LayoutCommandRequest {
        LayoutCommandRequest(
            inputDocumentPath: "input.json",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .translateShape(TranslateShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    delta: LayoutPoint(x: 5, y: 0)
                )),
                .resizeShape(ResizeShapeCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    deltaMinX: 0,
                    deltaMinY: 0,
                    deltaMaxX: -3,
                    deltaMaxY: 0
                )),
            ]
        )
    }

    private func expectNoArtifacts(_ artifactURLs: [URL]) {
        for artifactURL in artifactURLs {
            #expect(!FileManager.default.fileExists(atPath: artifactURL.path))
        }
    }

    private func expectInputDocumentUnchanged(_ fixture: RollbackFixture) throws {
        let reloaded = try fixture.serializer.decodeDocument(Data(contentsOf: fixture.inputURL))
        let cell = try #require(reloaded.cell(withID: cellID))
        let shape = try #require(cell.shapes.first { $0.id == shapeID })
        if case .rect(let rect) = shape.geometry {
            #expect(rect.origin == LayoutPoint(x: 0, y: 0))
            #expect(rect.size == LayoutSize(width: 2, height: 1))
        } else {
            Issue.record("Expected original rectangle geometry")
        }
    }

    @Test("Action domain exporter describes implemented layout commands")
    func actionDomainExporterDescribesImplementedLayoutCommands() throws {
        let snapshot = LayoutActionDomainExporter().snapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.domainID == "layout-edit")
        #expect(snapshot.ownerPackages == ["semiconductor-layout"])

        let operationIDs = Set(snapshot.operations.map(\.operationID))
        #expect(operationIDs.contains("layout-command-replay"))
        #expect(operationIDs.contains("layout.create-cell"))
        #expect(operationIDs.contains("layout.add-net"))
        #expect(operationIDs.contains("layout.add-rect"))
        #expect(operationIDs.contains("layout.add-shape"))
        #expect(operationIDs.contains("layout.finish-net"))
        #expect(operationIDs.contains("layout.translate-shape"))
        #expect(operationIDs.contains("layout.resize-shape"))
        #expect(operationIDs.contains("layout.delete-shape"))
        #expect(operationIDs.contains("layout.split-shape"))
        #expect(operationIDs.contains("layout.add-label"))
        #expect(operationIDs.contains("layout.add-via"))
        #expect(operationIDs.contains("layout.add-guard-ring"))
        #expect(operationIDs.contains("layout.add-instance"))
        #expect(operationIDs.contains("layout.move-instance"))
        #expect(operationIDs.contains("layout.rotate-instance"))
        #expect(operationIDs.contains("layout.mirror-instance"))
        #expect(operationIDs.contains("layout.flatten-instance"))
        #expect(operationIDs.contains("layout.make-cell"))
        #expect(operationIDs.contains("layout.fix-all-violations"))

        let addRect = try #require(snapshot.operations.first { $0.operationID == "layout.add-rect" })
        #expect(addRect.maturity == "implemented")
        #expect(addRect.preconditions.contains("positive-rect-size"))
        #expect(addRect.preconditions.contains("net-ref-exists-when-present"))
        #expect(addRect.verificationGates.contains("native-drc"))
        #expect(addRect.reversible)

        let addShape = try #require(snapshot.operations.first { $0.operationID == "layout.add-shape" })
        #expect(addShape.maturity == "implemented")
        #expect(addShape.inputRefs.contains("geometry"))
        #expect(addShape.preconditions.contains("valid-shape-geometry"))
        #expect(addShape.preconditions.contains("net-ref-exists-when-present"))
        #expect(addShape.verificationGates.contains("native-drc"))
        #expect(addShape.verificationGates.contains("native-lvs"))
        #expect(addShape.reversible)

        let finishNet = try #require(snapshot.operations.first { $0.operationID == "layout.finish-net" })
        #expect(finishNet.maturity == "implemented")
        #expect(finishNet.inputRefs.contains("route-policy"))
        #expect(finishNet.inputRefs.contains("route-endpoints"))
        #expect(finishNet.inputRefs.contains("optional-technology-profile-ref"))
        #expect(finishNet.inputRefs.contains("optional-finish-net-report-ref"))
        #expect(finishNet.preconditions.contains("net-exists"))
        #expect(finishNet.preconditions.contains("explicit-route-or-open-net-flyline-available"))
        #expect(finishNet.effects.contains("route-shapes-created"))
        #expect(finishNet.effects.contains("optional-drc-report-produced"))
        #expect(finishNet.effects.contains("optional-open-net-reduction-verified"))
        #expect(finishNet.producedArtifacts.contains("layout-finish-net-report"))
        #expect(finishNet.verificationGates.contains("native-drc"))
        #expect(finishNet.verificationGates.contains("native-lvs"))
        #expect(finishNet.verificationGates.contains("optional-finish-net-drc-report"))
        #expect(finishNet.verificationGates.contains("optional-open-net-auto-route-gate"))

        let resizeShape = try #require(snapshot.operations.first { $0.operationID == "layout.resize-shape" })
        #expect(resizeShape.maturity == "implemented")
        #expect(resizeShape.preconditions.contains("shape-is-resizable"))
        #expect(resizeShape.preconditions.contains("positive-resized-bounds"))
        #expect(resizeShape.effects.contains("shape-bounds-updated"))
        #expect(resizeShape.verificationGates.contains("native-drc"))

        let deleteShape = try #require(snapshot.operations.first { $0.operationID == "layout.delete-shape" })
        #expect(deleteShape.maturity == "implemented")
        #expect(deleteShape.preconditions.contains("delete-policy-approved"))
        #expect(deleteShape.effects.contains("shape-deleted"))
        #expect(deleteShape.verificationGates.contains("native-lvs"))

        let splitShape = try #require(snapshot.operations.first { $0.operationID == "layout.split-shape" })
        #expect(splitShape.maturity == "implemented")
        #expect(splitShape.preconditions.contains("shape-is-splittable"))
        #expect(splitShape.preconditions.contains("valid-split-coordinate"))
        #expect(splitShape.effects.contains("shape-split"))
        #expect(splitShape.effects.contains("child-shapes-created"))
        #expect(splitShape.verificationGates.contains("native-drc"))

        let addInstance = try #require(snapshot.operations.first { $0.operationID == "layout.add-instance" })
        #expect(addInstance.maturity == "implemented")
        #expect(addInstance.inputRefs.contains("terminal-net-bindings"))
        #expect(addInstance.preconditions.contains("acyclic-cell-hierarchy"))
        #expect(addInstance.preconditions.contains("terminal-net-refs-exist-when-present"))
        #expect(addInstance.effects.contains("instance-created"))
        #expect(addInstance.verificationGates.contains("native-lvs"))

        let addGuardRing = try #require(snapshot.operations.first { $0.operationID == "layout.add-guard-ring" })
        #expect(addGuardRing.maturity == "implemented")
        #expect(addGuardRing.inputRefs.contains("guard-ring-request"))
        #expect(addGuardRing.preconditions.contains("guard-ring-rules-available"))
        #expect(addGuardRing.effects.contains("guard-ring-contact-array-created"))
        #expect(addGuardRing.producedArtifacts.contains("layout-guard-ring-report"))
        #expect(addGuardRing.verificationGates.contains("native-drc"))

        let moveInstance = try #require(snapshot.operations.first { $0.operationID == "layout.move-instance" })
        #expect(moveInstance.maturity == "implemented")
        #expect(moveInstance.effects.contains("instance-translation-updated"))

        let flattenInstance = try #require(snapshot.operations.first { $0.operationID == "layout.flatten-instance" })
        #expect(flattenInstance.maturity == "implemented")
        #expect(flattenInstance.effects.contains("deterministic-copy-ids-created"))

        let makeCell = try #require(snapshot.operations.first { $0.operationID == "layout.make-cell" })
        #expect(makeCell.maturity == "implemented")
        #expect(makeCell.preconditions.contains("acyclic-resulting-hierarchy"))

        let fixAll = try #require(snapshot.operations.first { $0.operationID == "layout.fix-all-violations" })
        #expect(fixAll.maturity == "implemented")
        #expect(fixAll.inputRefs.contains("technology-profile-ref"))
        #expect(fixAll.effects.contains("verified-repair-deltas-applied"))
        #expect(fixAll.effects.contains("residual-violations-reported"))
        #expect(fixAll.producedArtifacts.contains("layout-repair-sweep-report"))
        #expect(fixAll.verificationGates.contains("repair-delta-verification"))
    }

    @Test("Action domain snapshot satisfies agent operation contract")
    func actionDomainSnapshotSatisfiesAgentOperationContract() throws {
        let snapshot = LayoutActionDomainExporter().snapshot()
        let operationIDs = snapshot.operations.map(\.operationID)

        #expect(operationIDs.count == Set(operationIDs).count)
        #expect(snapshot.operations.count == 22)

        let requiredOperationIDs: Set<String> = [
            "layout-command-replay",
            "layout.create-cell",
            "layout.add-net",
            "layout.add-rect",
            "layout.add-shape",
            "layout.finish-net",
            "layout.translate-shape",
            "layout.resize-shape",
            "layout.delete-shape",
            "layout.split-shape",
            "layout.add-label",
            "layout.add-via",
            "layout.add-constraint",
            "layout.add-guard-ring",
            "layout.add-instance",
            "layout.move-instance",
            "layout.rotate-instance",
            "layout.mirror-instance",
            "layout.flatten-instance",
            "layout.make-cell",
            "layout.fix-all-violations",
            "layout.validate-constraints",
        ]
        #expect(Set(operationIDs) == requiredOperationIDs)

        for operation in snapshot.operations {
            #expect(operation.maturity == "implemented")
            #expect(!operation.inputRefs.isEmpty, "\(operation.operationID) must expose machine-readable inputs")
            #expect(!operation.preconditions.isEmpty, "\(operation.operationID) must expose preconditions")
            #expect(!operation.effects.isEmpty, "\(operation.operationID) must expose effects")
            #expect(!operation.producedArtifacts.isEmpty, "\(operation.operationID) must expose produced artifacts")
            #expect(operation.verificationGates.contains("artifact-integrity"))
            #expect(operation.inputRefs.count == Set(operation.inputRefs).count)
            #expect(operation.preconditions.count == Set(operation.preconditions).count)
            #expect(operation.effects.count == Set(operation.effects).count)
            #expect(operation.producedArtifacts.count == Set(operation.producedArtifacts).count)
            #expect(operation.verificationGates.count == Set(operation.verificationGates).count)
        }

        let replay = try #require(snapshot.operations.first { $0.operationID == "layout-command-replay" })
        #expect(replay.reversible == false)
        let nonReversibleOperationIDs: Set<String> = [
            "layout-command-replay",
            "layout.validate-constraints",
        ]
        #expect(Set(snapshot.operations.filter(\.reversible).map(\.operationID)) == requiredOperationIDs.subtracting(nonReversibleOperationIDs))

        let geometryEditIDs: Set<String> = [
            "layout.add-rect",
            "layout.add-shape",
            "layout.finish-net",
            "layout.translate-shape",
            "layout.resize-shape",
            "layout.delete-shape",
            "layout.split-shape",
            "layout.add-via",
            "layout.add-instance",
            "layout.move-instance",
            "layout.rotate-instance",
            "layout.mirror-instance",
            "layout.flatten-instance",
            "layout.fix-all-violations",
        ]
        for operation in snapshot.operations where geometryEditIDs.contains(operation.operationID) {
            #expect(operation.verificationGates.contains("native-drc"), "\(operation.operationID) must be DRC-verifiable")
        }

        let electricalEditIDs: Set<String> = [
            "layout.add-shape",
            "layout.finish-net",
            "layout.translate-shape",
            "layout.resize-shape",
            "layout.delete-shape",
            "layout.split-shape",
            "layout.add-label",
            "layout.add-via",
            "layout.add-instance",
            "layout.move-instance",
            "layout.rotate-instance",
            "layout.mirror-instance",
            "layout.flatten-instance",
        ]
        for operation in snapshot.operations where electricalEditIDs.contains(operation.operationID) {
            #expect(operation.verificationGates.contains("native-lvs"), "\(operation.operationID) must be LVS-verifiable")
        }

        let optionalNetOperationIDs: Set<String> = [
            "layout.add-rect",
            "layout.add-shape",
            "layout.add-label",
            "layout.add-via",
        ]
        for operation in snapshot.operations where optionalNetOperationIDs.contains(operation.operationID) {
            #expect(operation.inputRefs.contains("optional-net-ref"))
            #expect(operation.preconditions.contains("net-ref-exists-when-present"))
        }
    }

    @Test("CLI service emits action-domain JSON")
    func cliServiceEmitsActionDomainJSON() throws {
        let output = try LayoutCommandCLIService().run(
            options: LayoutCommandCLIOptions(arguments: ["--action-domain", "--json"])
        )
        let data = try #require(output.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(LayoutActionDomainSnapshot.self, from: data)

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.domainID == "layout-edit")
        #expect(snapshot.operations.count == 22)
        #expect(output.contains(#""operations" : ["#))
        #expect(output.contains(#""operationID" : "layout.add-rect""#))
        #expect(output.contains(#""operationID" : "layout.add-shape""#))
        #expect(output.contains(#""operationID" : "layout.finish-net""#))
        #expect(output.contains(#""operationID" : "layout.add-guard-ring""#))
        #expect(output.contains(#""operationID" : "layout.validate-constraints""#))
        #expect(output.contains(#""verificationGates" : ["#))
        #expect(!output.contains("layout-command action-domain"))
    }

    @Test("CLI service rejects action-domain mixed with request")
    func cliServiceRejectsActionDomainMixedWithRequest() throws {
        #expect(throws: LayoutCommandError.conflictingArguments("--request", "--action-domain")) {
            _ = try LayoutCommandCLIOptions(arguments: [
                "--request",
                "/tmp/request.json",
                "--action-domain",
                "--json",
            ])
        }
    }

    @Test("CLI service rejects missing action-domain command mode")
    func cliServiceRejectsMissingActionDomainCommandMode() throws {
        #expect(throws: LayoutCommandError.missingCommandMode) {
            _ = try LayoutCommandCLIOptions(arguments: ["--json"])
        }
    }

    @Test("CLI service executes bundled request fixture")
    func cliServiceExecutesBundledRequestFixture() throws {
        let outputRoot = URL(fileURLWithPath: "/tmp/layout-command-fixture", isDirectory: true)
        if FileManager.default.fileExists(atPath: outputRoot.path) {
            try FileManager.default.removeItem(at: outputRoot)
        }

        let requestURL = try #require(Bundle.module.url(
            forResource: "basic-layout-command-request",
            withExtension: "json"
        ))
        let output = try LayoutCommandCLIService().run(
            options: LayoutCommandCLIOptions(arguments: ["--request", requestURL.path, "--json"])
        )
        let data = try #require(output.data(using: .utf8))
        let result = try JSONDecoder().decode(LayoutCommandResult.self, from: data)

        #expect(result.status == "passed")
        #expect(result.commandCount == 4)
        #expect(result.shapeCount == 1)
        #expect(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("layout.json").path))
        #expect(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("result.json").path))
    }

    @Test("CLI service produces stable layout artifact digest for replayed requests")
    func cliServiceProducesStableLayoutArtifactDigestForReplayedRequests() throws {
        let roots = try makeStableDigestRoots()
        defer { removeTemporaryRoots(roots.all) }
        let request = stableDigestRequest(layer: LayoutLayerID(name: "M1", purpose: "drawing"))

        let results = try runStableDigestRequests(request, roots: roots)

        try expectStableDigestResults(results)
        try expectStableDigestArtifacts(roots: roots, firstResult: results.first)
    }

    private struct StableDigestRoots {
        let first: URL
        let second: URL

        var all: [URL] { [first, second] }
    }

    private struct StableDigestResults {
        let first: LayoutCommandResult
        let second: LayoutCommandResult
    }

    private func makeStableDigestRoots() throws -> StableDigestRoots {
        StableDigestRoots(
            first: try makeTemporaryRoot(prefix: "LayoutCommandCLIStableDigestA"),
            second: try makeTemporaryRoot(prefix: "LayoutCommandCLIStableDigestB")
        )
    }

    private func stableDigestRequest(layer: LayoutLayerID) -> LayoutCommandRequest {
        LayoutCommandRequest(
            documentID: documentID,
            documentName: "stable-agent-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
                .addRect(AddRectCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    layer: layer,
                    origin: LayoutPoint(x: 1, y: 2),
                    size: LayoutSize(width: 3, height: 4),
                    netID: netID,
                    properties: ["intent": "agent-replay"]
                )),
                .addLabel(AddLabelCommand(
                    cellID: cellID,
                    labelID: labelID,
                    text: "sig",
                    position: LayoutPoint(x: 2, y: 3),
                    layer: layer,
                    netID: netID
                )),
            ]
        )
    }

    private func runStableDigestRequests(
        _ request: LayoutCommandRequest,
        roots: StableDigestRoots
    ) throws -> StableDigestResults {
        StableDigestResults(
            first: try runCLIRequest(request, in: roots.first),
            second: try runCLIRequest(request, in: roots.second)
        )
    }

    private func expectStableDigestResults(_ results: StableDigestResults) throws {
        #expect(results.first.status == "passed")
        #expect(results.second.status == "passed")
        #expect(results.first.commandCount == 4)
        #expect(results.second.commandCount == 4)
        #expect(results.first.outputDocumentSHA256 == results.second.outputDocumentSHA256)
        #expect(results.first.outputDocumentByteCount == results.second.outputDocumentByteCount)
        #expect(results.first.appliedCommands == results.second.appliedCommands)
    }

    private func expectStableDigestArtifacts(
        roots: StableDigestRoots,
        firstResult: LayoutCommandResult
    ) throws {
        let firstDocumentData = try Data(contentsOf: roots.first.appendingPathComponent("artifacts/layout.json"))
        let secondDocumentData = try Data(contentsOf: roots.second.appendingPathComponent("artifacts/layout.json"))
        #expect(firstDocumentData == secondDocumentData)

        let firstManifest = try JSONDecoder().decode(
            LayoutCommandArtifactManifest.self,
            from: Data(contentsOf: roots.first.appendingPathComponent("artifacts/manifest.json"))
        )
        let layoutArtifact = try #require(firstManifest.artifacts.first { $0.id == "output-layout-document" })
        #expect(layoutArtifact.sha256 == firstResult.outputDocumentSHA256)
        #expect(layoutArtifact.byteCount == firstDocumentData.count)
    }

    private func removeTemporaryRoots(_ roots: [URL]) {
        for root in roots {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove temporary directory: \(error)")
            }
        }
    }

    @Test("CLI service leaves no artifacts when a request fails")
    func cliServiceLeavesNoArtifactsWhenRequestFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutCommandCLIServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove temporary directory: \(error)")
            }
        }

        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "failed-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addRect(AddRectCommand(
                    cellID: cellID,
                    shapeID: shapeID,
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    origin: LayoutPoint(x: 0, y: 0),
                    size: LayoutSize(width: -1, height: 1)
                )),
            ]
        )
        let requestURL = root.appendingPathComponent("request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: [.atomic])

        #expect(throws: LayoutCommandError.invalidRectSize(width: -1, height: 1)) {
            _ = try LayoutCommandCLIService().run(
                options: LayoutCommandCLIOptions(arguments: ["--request", requestURL.path, "--json"])
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
    }

    private func runCLIRequest(_ request: LayoutCommandRequest, in root: URL) throws -> LayoutCommandResult {
        let requestURL = root.appendingPathComponent("request.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: [.atomic])

        let output = try LayoutCommandCLIService().run(
            options: LayoutCommandCLIOptions(arguments: ["--request", requestURL.path, "--json"])
        )
        let data = try #require(output.data(using: .utf8))
        return try JSONDecoder().decode(LayoutCommandResult.self, from: data)
    }

    private static func makeRepairTech(layer: LayoutLayerID) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: layer,
                    displayName: "Metal1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                ),
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: layer,
                    minWidth: 0.2,
                    minSpacing: 0.2,
                    minArea: 0.01,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ]
        )
    }
}
