import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// N3 contract: one command turns an intent open into a clean
/// connection, or refuses with the reason and leaves the document
/// bit-exact.
@MainActor
@Suite("finish-net", .timeLimit(.minutes(2)))
struct FinishNetTests {

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

    private static func twoPadDocument(netID: UUID, gapTo secondX: Double = 5) -> LayoutDocument {
        let left = LayoutShape(
            layer: m1,
            netID: netID,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.4)))
        )
        let right = LayoutShape(
            layer: m1,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: secondX, y: 0),
                size: LayoutSize(width: 1, height: 0.4)
            ))
        )
        let cell = LayoutCell(name: "TOP", shapes: [left, right])
        return LayoutDocument(name: "net", cells: [cell], topCellID: cell.id)
    }

    @Test func finishNetClosesTheOpenAndStaysClean() throws {
        let netID = UUID()
        let viewModel = LayoutEditorViewModel(
            document: Self.twoPadDocument(netID: netID),
            tech: Self.makeTech()
        )
        #expect(viewModel.connectivityAnalysis?.flylines.count == 1)

        let finished = viewModel.finishNet(netID)

        #expect(finished)
        #expect(viewModel.connectivityAnalysis?.flylines.isEmpty == true)
        #expect(viewModel.connectivityAnalysis?.opens.isEmpty == true)
        #expect(viewModel.violations.isEmpty, "the connection must be DRC clean")

        viewModel.undo()
        #expect(viewModel.connectivityAnalysis?.flylines.count == 1,
                "one finish-net is one undo unit")
    }

    @Test func finishNetRefusesAWalledNetAndLeavesTheDocumentUntouched() throws {
        let netID = UUID()
        var document = Self.twoPadDocument(netID: netID)
        // A foreign wall far taller than the search window between the
        // pads.
        var cell = try #require(document.cells.first)
        cell.shapes.append(LayoutShape(
            layer: Self.m1,
            netID: UUID(),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 2.5, y: -60),
                size: LayoutSize(width: 0.4, height: 120)
            ))
        ))
        document.updateCell(cell)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.makeTech())
        let flattenBefore = viewModel.flattenedDocumentShapes().count

        let finished = viewModel.finishNet(netID)

        #expect(!finished)
        #expect(viewModel.lastError != nil, "the refusal must carry its reason")
        #expect(viewModel.flattenedDocumentShapes().count == flattenBefore,
                "a refused finish-net must not touch the document")
        #expect(viewModel.connectivityAnalysis?.flylines.count == 1)
    }

    @Test func finishAllNetsCompletesEveryFinishableNet() throws {
        let netA = UUID()
        let netB = UUID()
        var shapes: [LayoutShape] = []
        for (net, y) in [(netA, 0.0), (netB, 10.0)] {
            shapes.append(LayoutShape(
                layer: Self.m1,
                netID: net,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: y),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ))
            shapes.append(LayoutShape(
                layer: Self.m1,
                netID: net,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 5, y: y),
                    size: LayoutSize(width: 1, height: 0.4)
                ))
            ))
        }
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        let document = LayoutDocument(name: "nets", cells: [cell], topCellID: cell.id)
        let viewModel = LayoutEditorViewModel(document: document, tech: Self.makeTech())
        #expect(viewModel.connectivityAnalysis?.flylines.count == 2)

        let completed = viewModel.finishAllNets()

        #expect(completed == 2)
        #expect(viewModel.connectivityAnalysis?.flylines.isEmpty == true)
        #expect(viewModel.violations.isEmpty)
    }
}
