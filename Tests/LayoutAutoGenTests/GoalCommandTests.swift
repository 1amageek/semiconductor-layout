import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// N5 contract: goal commands are deterministic and auditable. The same
/// document plus the same command sequence yields the same geometry and
/// the same verdict records, whether driven by a human keymap or an
/// agent.
@MainActor
@Suite("Goal commands", .timeLimit(.minutes(2)))
struct GoalCommandTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    private static func makeTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: m1,
                    displayName: "M1",
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            ],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0.2,
                    minSpacing: 0.2,
                    minArea: 0.01,
                    minDensity: 0,
                    maxDensity: 1
                )
            ]
        )
    }

    /// A document with one spacing violation, one width violation, and
    /// one labeled-but-open net.
    private static func fixture() -> LayoutDocument {
        let netA = UUID()
        let netB = UUID()
        let shapes = [
            LayoutShape(
                layer: m1,
                netID: netA,
                geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
            ),
            LayoutShape(
                layer: m1,
                netID: netB,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.1, y: 0),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 5),
                    size: LayoutSize(width: 0.1, height: 1)
                ))
            ),
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 10),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: m1,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 6, y: 10),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ),
        ]
        let labels = [
            LayoutLabel(text: "X", position: LayoutPoint(x: 0.5, y: 10.2), layer: m1),
            LayoutLabel(text: "X", position: LayoutPoint(x: 6.5, y: 10.2), layer: m1),
        ]
        let cell = LayoutCell(name: "TOP", shapes: shapes, labels: labels)
        return LayoutDocument(name: "goal", cells: [cell], topCellID: cell.id)
    }

    private static let script: [LayoutGoalCommand] = [
        .annotateNetsFromLabels,
        .fixAllViolations,
        .finishAllNets,
    ]

    private static func stamps(_ viewModel: LayoutEditorViewModel) -> [String: Int] {
        var result: [String: Int] = [:]
        for shape in viewModel.flattenedDocumentShapes() {
            let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            let key = String(
                format: "%@|%.3f|%.3f|%.3f|%.3f",
                shape.layer.name, box.minX, box.minY, box.size.width, box.size.height
            )
            result[key, default: 0] += 1
        }
        return result
    }

    @Test func scriptDrivesTheDocumentToCleanAndConnected() throws {
        let viewModel = LayoutEditorViewModel(document: Self.fixture(), tech: Self.makeTech())
        #expect(!viewModel.violations.isEmpty)

        let allSucceeded = viewModel.replay(Self.script)

        #expect(allSucceeded)
        #expect(viewModel.violations.isEmpty)
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == true)
        #expect(viewModel.goalLog.count == Self.script.count)
        let last = try #require(viewModel.goalLog.last)
        #expect(last.opensAfter == 0)
    }

    @Test func replayIsDeterministicAcrossFreshEditors() {
        let first = LayoutEditorViewModel(document: Self.fixture(), tech: Self.makeTech())
        let second = LayoutEditorViewModel(document: Self.fixture(), tech: Self.makeTech())
        // Different documents (fresh UUIDs) but identical geometry and
        // identical scripts must land on identical geometry and records.
        first.replay(Self.script)
        second.replay(Self.script)

        #expect(Self.stamps(first) == Self.stamps(second))
        #expect(first.goalLog.map(\.succeeded) == second.goalLog.map(\.succeeded))
        #expect(first.goalLog.map(\.violationsAfter) == second.goalLog.map(\.violationsAfter))
        #expect(first.goalLog.map(\.opensAfter) == second.goalLog.map(\.opensAfter))
    }

    @Test func unknownIntentDeviceFailsWithReasonAndIsLogged() {
        let viewModel = LayoutEditorViewModel(document: Self.fixture(), tech: Self.makeTech())

        let succeeded = viewModel.execute(.placeIntentDevice(deviceID: "ghost", at: .zero))

        #expect(!succeeded)
        #expect(viewModel.lastError != nil)
        #expect(viewModel.goalLog.last?.succeeded == false)
    }
}
