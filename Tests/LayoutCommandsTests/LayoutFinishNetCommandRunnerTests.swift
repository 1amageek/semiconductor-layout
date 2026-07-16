import CircuiteFoundation
import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import Testing

@Suite("Layout finish-net command runner")
struct LayoutFinishNetCommandRunnerTests {
    private let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let cellID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let netID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let shapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @Test("Runner finishes a net with reproducible route shape IDs")
    func runnerFinishesNetWithReproducibleRouteShapeIDs() throws {
        let root = try makeRoot()
        let firstRouteShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let secondRouteShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let serializer = LayoutDocumentSerializer()
        let tech = Self.makeTech(layer: layer)
        try serializer.encodeTech(tech).write(to: root.appendingPathComponent("tech.json"), options: [.atomic])
        let command = explicitFinishNetCommand(
            layer: layer,
            firstRouteShapeID: firstRouteShapeID,
            secondRouteShapeID: secondRouteShapeID
        )
        let request = finishNetRequest(documentName: "finish-net-layout", commands: [
            .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
            .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
            .finishNet(command),
        ])

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        expectExplicitFinishNetResult(result)
        try expectExplicitFinishNetDocument(root: root, serializer: serializer, firstID: firstRouteShapeID, secondID: secondRouteShapeID)
        let reportData = try expectExplicitFinishNetReport(root: root, command: command, routeShapeIDs: [firstRouteShapeID, secondRouteShapeID])
        try expectFinishNetReportArtifact(root: root, artifactID: "layout-finish-net-2", reportData: reportData)
    }

    @Test("Explicit finish-net verdict ignores pre-existing unrelated DRC violations")
    func explicitFinishNetVerdictIgnoresPreExistingUnrelatedDRCViolations() throws {
        let root = try makeRoot()
        let firstRouteShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let secondRouteShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        let unrelatedShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let serializer = LayoutDocumentSerializer()
        let tech = Self.makeTech(layer: layer)
        try serializer.encodeTech(tech).write(to: root.appendingPathComponent("tech.json"), options: [.atomic])
        let command = explicitFinishNetCommand(
            layer: layer,
            firstRouteShapeID: firstRouteShapeID,
            secondRouteShapeID: secondRouteShapeID
        )
        let request = finishNetRequest(documentName: "finish-net-existing-drc-layout", commands: [
            .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
            .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
            .addRect(AddRectCommand(
                cellID: cellID,
                shapeID: unrelatedShapeID,
                layer: layer,
                origin: LayoutPoint(x: 20, y: 20),
                size: LayoutSize(width: 0.1, height: 1)
            )),
            .finishNet(command),
        ])

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        #expect(result.status == "passed")
        let reportURL = root.appendingPathComponent("artifacts/finish-net-report.json")
        let reportData = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(LayoutFinishNetReport.self, from: reportData)
        #expect(report.status == "passed")
        #expect(report.violationCount >= 1)
        #expect(report.errorCount >= 1)
        #expect(report.routeViolationCount == 0)
        #expect(report.verificationStatus == "route-drc-verified")
    }

    @Test("Runner rejects finish-net reports without a technology path")
    func runnerRejectsFinishNetReportsWithoutTechnologyPath() throws {
        let root = try makeRoot()
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "invalid-finish-net-report-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
                .finishNet(FinishNetCommand(
                    cellID: cellID,
                    netID: netID,
                    layer: layer,
                    start: LayoutPoint(x: 0, y: 0),
                    end: LayoutPoint(x: 3, y: 0),
                    width: 0.4,
                    firstShapeID: shapeID,
                    reportPath: "artifacts/finish-net-report.json"
                )),
            ]
        )

        #expect(throws: LayoutCommandError.missingRequiredArgument("finishNet.technologyPath")) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/finish-net-report.json").path))
    }

    @Test("Runner auto-routes an open net through the verified finish-net planner")
    func runnerAutoRoutesOpenNetThroughVerifiedFinishNetPlanner() throws {
        let root = try makeRoot()
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let leftShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let rightShapeID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let serializer = LayoutDocumentSerializer()
        let tech = Self.makeTech(layer: layer)
        try serializer.encodeTech(tech).write(to: root.appendingPathComponent("tech.json"), options: [.atomic])

        let request = finishNetRequest(documentName: "verified-finish-net-layout", commands: [
            .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
            .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
            .addRect(openNetRect(shapeID: leftShapeID, layer: layer, origin: .zero)),
            .addRect(openNetRect(shapeID: rightShapeID, layer: layer, origin: LayoutPoint(x: 5, y: 0))),
            .finishNet(autoRouteFinishNetCommand(layer: layer)),
        ])

        let result = try LayoutCommandRunner().run(request: request, baseURL: root)

        #expect(result.status == "passed")
        #expect(result.commandCount == 5)
        try expectOpenNetClosed(root: root, serializer: serializer, tech: tech)
        let reportData = try expectAutoRouteReport(root: root)
        try expectFinishNetReportArtifact(root: root, artifactID: "layout-finish-net-4", reportData: reportData)
    }

    @Test("Runner rejects L routes without a second explicit route shape ID")
    func runnerRejectsLRoutesWithoutSecondExplicitRouteShapeID() throws {
        let root = try makeRoot()
        let request = LayoutCommandRequest(
            documentID: documentID,
            documentName: "invalid-finish-net-layout",
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: [
                .createCell(CreateCellCommand(cellID: cellID, name: "top", makeTop: true)),
                .addNet(AddNetCommand(cellID: cellID, netID: netID, name: "sig")),
                .finishNet(FinishNetCommand(
                    cellID: cellID,
                    netID: netID,
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    start: LayoutPoint(x: 0, y: 0),
                    end: LayoutPoint(x: 1, y: 1),
                    width: 0.2,
                    firstShapeID: shapeID
                )),
            ]
        )

        #expect(throws: LayoutCommandError.missingRouteShapeID("vertical")) {
            _ = try LayoutCommandRunner().run(request: request, baseURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/layout.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/result.json").path))
    }

    @Test("Headless finish-net planner rejects invalid route width")
    func plannerRejectsInvalidRouteWidth() throws {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let leftShapeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051"))
        let rightShapeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000052"))
        let document = openNetDocument(layer: layer, leftShapeID: leftShapeID, rightShapeID: rightShapeID)
        let tech = Self.makeTech(layer: layer)

        #expect(throws: HeadlessFinishNetPlannerError.invalidRouteWidth(0)) {
            _ = try HeadlessFinishNetPlanner().plan(
                document: document,
                tech: tech,
                cellID: cellID,
                netID: netID,
                layer: layer,
                width: 0,
                shapeIDSeed: "invalid-width"
            )
        }
    }

    @Test("Headless finish-net planner rejects deterministic route shape ID collisions")
    func plannerRejectsDeterministicRouteShapeIDCollisions() throws {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let leftShapeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000061"))
        let rightShapeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000062"))
        let document = openNetDocument(layer: layer, leftShapeID: leftShapeID, rightShapeID: rightShapeID)
        let tech = Self.makeTech(layer: layer)
        let seed = "shape-collision"
        let initialPlan = try HeadlessFinishNetPlanner().plan(
            document: document,
            tech: tech,
            cellID: cellID,
            netID: netID,
            layer: layer,
            width: 0.2,
            shapeIDSeed: seed
        )
        let collidingID = try #require(initialPlan.routeShapeIDs.first)
        var collidingDocument = document
        var cell = try #require(collidingDocument.cell(withID: cellID))
        cell.shapes.append(LayoutShape(
            id: collidingID,
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 100, y: 100),
                size: LayoutSize(width: 0.2, height: 0.2)
            ))
        ))
        collidingDocument.updateCell(cell)

        #expect(throws: HeadlessFinishNetPlannerError.routeShapeIDCollision(collidingID)) {
            _ = try HeadlessFinishNetPlanner().plan(
                document: collidingDocument,
                tech: tech,
                cellID: cellID,
                netID: netID,
                layer: layer,
                width: 0.2,
                shapeIDSeed: seed
            )
        }
    }

    private func finishNetRequest(
        documentName: String,
        commands: [LayoutCommand]
    ) -> LayoutCommandRequest {
        LayoutCommandRequest(
            documentID: documentID,
            documentName: documentName,
            outputDocumentPath: "artifacts/layout.json",
            artifactManifestPath: "artifacts/manifest.json",
            resultPath: "artifacts/result.json",
            commands: commands
        )
    }

    private func explicitFinishNetCommand(
        layer: LayoutLayerID,
        firstRouteShapeID: UUID,
        secondRouteShapeID: UUID
    ) -> FinishNetCommand {
        FinishNetCommand(
            cellID: cellID,
            netID: netID,
            layer: layer,
            start: LayoutPoint(x: 0, y: 0),
            end: LayoutPoint(x: 3, y: 2),
            width: 0.4,
            firstShapeID: firstRouteShapeID,
            secondShapeID: secondRouteShapeID,
            technologyPath: "tech.json",
            reportPath: "artifacts/finish-net-report.json",
            properties: ["intent": "finish-net"]
        )
    }

    private func autoRouteFinishNetCommand(layer: LayoutLayerID) -> FinishNetCommand {
        FinishNetCommand(
            cellID: cellID,
            netID: netID,
            layer: layer,
            start: .zero,
            end: .zero,
            width: 0.2,
            technologyPath: "tech.json",
            reportPath: "artifacts/finish-net-report.json",
            routePolicy: .openNetAutoRoute,
            properties: ["intent": "verified-finish-net"]
        )
    }

    private func openNetRect(
        shapeID: UUID,
        layer: LayoutLayerID,
        origin: LayoutPoint
    ) -> AddRectCommand {
        AddRectCommand(
            cellID: cellID,
            shapeID: shapeID,
            layer: layer,
            origin: origin,
            size: LayoutSize(width: 1, height: 0.4),
            netID: netID
        )
    }

    private func expectExplicitFinishNetResult(_ result: LayoutCommandResult) {
        #expect(result.status == "passed")
        #expect(result.commandCount == 3)
        #expect(result.shapeCount == 2)
        #expect(result.netCount == 1)
        #expect(result.appliedCommands.last == LayoutAppliedCommand(
            index: 2,
            kind: .finishNet,
            cellID: cellID,
            entityID: netID
        ))
    }

    private func expectExplicitFinishNetDocument(
        root: URL,
        serializer: LayoutDocumentSerializer,
        firstID: UUID,
        secondID: UUID
    ) throws {
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let document = try serializer.decodeDocument(Data(contentsOf: documentURL))
        let cell = try #require(document.cell(withID: cellID))
        let first = try #require(cell.shapes.first { $0.id == firstID })
        let second = try #require(cell.shapes.first { $0.id == secondID })
        #expect(first.netID == netID)
        #expect(second.netID == netID)
        #expect(first.properties["intent"] == "finish-net")
        #expect(second.properties["intent"] == "finish-net")
        expectRect(first, origin: LayoutPoint(x: -0.2, y: -0.2), size: LayoutSize(width: 3.4, height: 0.4))
        expectRect(second, origin: LayoutPoint(x: 2.8, y: -0.2), size: LayoutSize(width: 0.4, height: 2.4))
    }

    private func expectRect(_ shape: LayoutShape, origin: LayoutPoint, size: LayoutSize) {
        if case .rect(let rect) = shape.geometry {
            #expect(rect.origin == origin)
            #expect(rect.size == size)
        } else {
            Issue.record("Expected route rectangle")
        }
    }

    private func expectExplicitFinishNetReport(
        root: URL,
        command: FinishNetCommand,
        routeShapeIDs: [UUID]
    ) throws -> Data {
        let reportURL = root.appendingPathComponent("artifacts/finish-net-report.json")
        let reportData = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(LayoutFinishNetReport.self, from: reportData)
        #expect(report.status == "passed")
        #expect(report.commandIndex == 2)
        #expect(report.command == command)
        #expect(report.routeShapeIDs == routeShapeIDs)
        #expect(report.violationCount == 0)
        #expect(report.errorCount == 0)
        #expect(report.warningCount == 0)
        #expect(report.routeViolationCount == 0)
        #expect(report.violations.isEmpty)
        return reportData
    }

    private func expectOpenNetClosed(
        root: URL,
        serializer: LayoutDocumentSerializer,
        tech: LayoutTechDatabase
    ) throws {
        let documentURL = root.appendingPathComponent("artifacts/layout.json")
        let document = try serializer.decodeDocument(Data(contentsOf: documentURL))
        let analysis = try LayoutConnectivityExtractor().extract(document: document, tech: tech, cellID: cellID)
        #expect(analysis.flylines.filter { $0.netID == netID }.isEmpty)
        #expect(analysis.opens.filter { $0.netID == netID }.isEmpty)
    }

    private func expectAutoRouteReport(root: URL) throws -> Data {
        let reportURL = root.appendingPathComponent("artifacts/finish-net-report.json")
        let reportData = try Data(contentsOf: reportURL)
        let report = try JSONDecoder().decode(LayoutFinishNetReport.self, from: reportData)
        #expect(report.status == "passed")
        #expect(report.commandIndex == 4)
        #expect(report.command.routePolicy == .openNetAutoRoute)
        #expect(report.routeShapeIDs.count >= 1)
        #expect(report.opensBefore == 1)
        #expect(report.opensAfter == 0)
        #expect(report.shortsBefore == 0)
        #expect(report.shortsAfter == 0)
        #expect(report.verificationStatus == "open-net-auto-route-verified")
        return reportData
    }

    private func expectFinishNetReportArtifact(
        root: URL,
        artifactID: String,
        reportData: Data
    ) throws {
        let manifestURL = root.appendingPathComponent("artifacts/manifest.json")
        let manifest = try JSONDecoder().decode(
            EvidenceManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        if artifactID == "layout-finish-net-2" {
            #expect(manifest.artifacts.count == 3)
        }
        let reportURL = root.appendingPathComponent("artifacts/finish-net-report.json")
        let reportArtifact = try #require(manifest.artifacts.first { $0.locator.role.rawValue == artifactID })
        #expect(reportArtifact.kind == .report)
        #expect(reportArtifact.format == .json)
        #expect(reportArtifact.path == reportURL.path)
        #expect(reportArtifact.digest == (try SHA256ContentDigester().digest(data: reportData, using: .sha256)))
        #expect(reportArtifact.byteCount == UInt64(reportData.count))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutFinishNetCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openNetDocument(
        layer: LayoutLayerID,
        leftShapeID: UUID,
        rightShapeID: UUID
    ) -> LayoutDocument {
        let left = LayoutShape(
            id: leftShapeID,
            layer: layer,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: .zero,
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let right = LayoutShape(
            id: rightShapeID,
            layer: layer,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 5, y: 0),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let cell = LayoutCell(id: cellID, name: "top", shapes: [left, right])
        return LayoutDocument(name: "open-net", cells: [cell], topCellID: cell.id)
    }

    private static func makeTech(layer: LayoutLayerID) -> LayoutTechDatabase {
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
