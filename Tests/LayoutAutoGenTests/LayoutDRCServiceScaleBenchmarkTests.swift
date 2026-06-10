import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Wall-clock benchmark of the full DRC service on a synthetic routed
/// design: per-net horizontal M1 wires with M2 landing pads and vias.
/// The design is clean by construction, so the assertion doubles as an
/// end-to-end correctness check while the timing tracks kernel changes.
@Suite("LayoutDRCService Scale Benchmark", .serialized, .timeLimit(.minutes(10)))
struct LayoutDRCServiceScaleBenchmarkTests {

    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let via1 = LayoutLayerID(name: "VIA1", purpose: "drawing")

    private func makeTech() -> LayoutTechDatabase {
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

    /// Per row: one M1 wire on its own net, with M2 pads and vias dropped
    /// every third column. Every net is fully connected and every rule is
    /// satisfied by construction.
    private func makeDocument(rows: Int, cols: Int) -> LayoutDocument {
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

    private func runScale(rows: Int, cols: Int) {
        let document = makeDocument(rows: rows, cols: cols)
        let tech = makeTech()
        let shapeCount = document.cells.first?.shapes.count ?? 0
        let viaCount = document.cells.first?.vias.count ?? 0

        let clock = ContinuousClock()
        var result: LayoutDRCResult? = nil
        let duration = clock.measure {
            result = LayoutDRCService().run(document: document, tech: tech)
        }
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        print("[bench] drcService \(shapeCount)s/\(viaCount)v: \(String(format: "%.1f", ms))ms")

        #expect(result?.violations.isEmpty == true, "design is clean by construction: \(result?.violations.map(\.message) ?? [])")
    }

    @Test func smallScale() {
        runScale(rows: 40, cols: 40)
    }

    @Test func mediumScale() {
        runScale(rows: 80, cols: 80)
    }
}
