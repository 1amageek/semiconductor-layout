import Foundation
import Testing
import LayoutCore
import LayoutEditor
import LayoutTech
import LayoutVerify

/// M7 integrated tick: one `commitDelta` drives live DRC, connectivity,
/// constraints, and the render index in sequence — the real editing cost a
/// user feels per gesture step. The component benchmarks bound each system
/// alone; this one catches anything the editor adds on top (document
/// mutation, undo bookkeeping, verdict assembly).
@MainActor
@Suite("LayoutEditor integrated tick", .serialized, .timeLimit(.minutes(10)))
struct LayoutEditorTickBenchmarkTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private static let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private static let via1 = LayoutLayerID(name: "VIA1", purpose: "drawing")

    @Test func editorTickStaysInteractiveAtScale() throws {
        let rows = 500
        let cols = 500
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let document = Self.makeDocument(rows: rows, cols: cols)
        let tech = Self.makeTech()
        let clock = ContinuousClock()

        var builtViewModel: LayoutEditorViewModel? = nil
        let openDuration = clock.measure {
            builtViewModel = LayoutEditorViewModel(document: document, tech: tech)
        }
        let viewModel = try #require(builtViewModel)
        #expect(viewModel.violations.isEmpty, "benchmark design is clean by construction")

        // Two satisfied matching constraints keep the live constraint
        // session on the indexed skip path that real designs exercise.
        let pads = viewModel.documentShapes().filter { $0.layer == Self.m2 }
        try #require(pads.count >= 5)
        viewModel.addConstraint(.matching(LayoutMatchingConstraint(members: [pads[0].id, pads[1].id])))
        viewModel.addConstraint(.matching(LayoutMatchingConstraint(members: [pads[2].id, pads[3].id])))
        #expect(viewModel.constraintViolations.isEmpty)

        // Tick on a pad outside the constraint members: the common case.
        let pad = pads[4]
        viewModel.selectedShapeIDs = [pad.id]
        var samples: [Double] = []
        for _ in 0..<10 {
            let forth = clock.measure {
                viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: 0.02))
            }
            samples.append(Self.milliseconds(forth))
            let back = clock.measure {
                viewModel.moveSelectedShapes(by: LayoutPoint(x: 0, y: -0.02))
            }
            samples.append(Self.milliseconds(back))
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let worst = samples.last ?? 0
        #expect(viewModel.violations.isEmpty, "round-trip ticks must end clean")
        #expect(viewModel.constraintViolations.isEmpty)

        let shapeCount = viewModel.documentShapes().count
        func verdict(_ value: Double, _ target: Double) -> String {
            value <= target ? "MEETS" : "MISSES"
        }
        print("[bench] (\(configuration), \(shapeCount)s editor) open: \(String(format: "%.0f", Self.milliseconds(openDuration)))ms")
        print("[bench] (\(configuration)) integrated tick: median \(String(format: "%.2f", median))ms, max \(String(format: "%.2f", worst))ms (\(verdict(median, 10)) 10ms tick target)")

        // Generous caps over observed numbers; the honest verdict is in
        // the printed report.
        #expect(median < 500, "integrated editor tick regressed at scale")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func makeTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            layers: [m1, m2, via1].map { id in
                LayoutLayerDefinition(
                    id: id,
                    displayName: id.name,
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                )
            },
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: via1,
                    topLayer: m2,
                    bottomLayer: m1,
                    cutSize: LayoutSize(width: 0.22, height: 0.22),
                    enclosure: LayoutViaEnclosure(top: 0.05, bottom: 0.05),
                    cutSpacing: 0.25
                )
            ],
            layerRules: [
                LayoutLayerRuleSet(layerID: m1, minWidth: 0.23, minSpacing: 0.23, minArea: 0.1, minDensity: 0, maxDensity: 1),
                LayoutLayerRuleSet(layerID: m2, minWidth: 0.28, minSpacing: 0.28, minArea: 0.1, minDensity: 0, maxDensity: 1),
                LayoutLayerRuleSet(layerID: via1, minWidth: 0, minSpacing: 0.25, minArea: 0, minDensity: 0, maxDensity: 1),
            ]
        )
    }

    /// Same synthetic routed design as the verification benchmarks: per
    /// row one M1 wire on its own net with M2 pads and vias every third
    /// column.
    private static func makeDocument(rows: Int, cols: Int) -> LayoutDocument {
        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        let pitch = 1.0

        for r in 0..<rows {
            let netID = UUID()
            let y = Double(r) * pitch
            shapes.append(LayoutShape(
                layer: m1,
                netID: netID,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: y),
                    size: LayoutSize(width: Double(cols) * pitch, height: 0.4)
                ))
            ))
            for c in 0..<cols where (r + c) % 3 == 0 {
                let x = Double(c) * pitch
                shapes.append(LayoutShape(
                    layer: m2,
                    netID: netID,
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: x + 0.3, y: y),
                        size: LayoutSize(width: 0.4, height: 0.4)
                    ))
                ))
                vias.append(LayoutVia(
                    viaDefinitionID: "VIA1",
                    position: LayoutPoint(x: x + 0.5, y: y + 0.2),
                    netID: netID
                ))
            }
        }

        let cell = LayoutCell(name: "TOP", shapes: shapes, vias: vias)
        return LayoutDocument(name: "bench", cells: [cell], topCellID: cell.id)
    }
}
