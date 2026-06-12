import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Million-element proof for the live verification sessions, mirroring the
/// M6 render-index scale claim on the verification side. The fixture is
/// the same synthetic routed design as the 167k benchmark, scaled to ~1M
/// shapes + ~1M vias.
///
/// Note on the wire-move medians: the edited wire spans the full 1730 µm
/// row, so its dirty region genuinely covers ~1700 elements (every via
/// enclosure and pad short along the row) — the recompute cost scales
/// with the affected geometry, not with the design size. Compact edits
/// stay in the sub-millisecond range the 167k benchmark shows.
///
/// Gated behind `LSI_SCALE_1M=1`: a million-element session init takes
/// minutes in debug, which would dominate every routine test run. The
/// gate is a visible skip, not a silent one — Swift Testing reports the
/// suite as disabled when the variable is absent.
@Suite(
    "LayoutVerify 1M scale",
    .serialized,
    .timeLimit(.minutes(30)),
    .enabled(if: ProcessInfo.processInfo.environment["LSI_SCALE_1M"] == "1")
)
struct LayoutVerifyMillionScaleTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private static let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private static let via1 = LayoutLayerID(name: "VIA1", purpose: "drawing")

    @Test func liveSessionsHandleAMillionShapes() throws {
        let rows = 1730
        let cols = 1730
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let document = Self.makeDocument(rows: rows, cols: cols)
        let tech = Self.makeTech()
        let topCell = try #require(document.cells.first)
        let clock = ContinuousClock()
        let shapeCount = topCell.shapes.count
        let viaCount = topCell.vias.count

        let midY = Double(rows / 2)
        let wire = try #require(
            topCell.shapes.first {
                $0.layer == Self.m1
                    && LayoutGeometryAnalysis.boundingBox(for: $0.geometry).origin.y == midY
            }
        )

        var drcSession: IncrementalDRCSession? = nil
        let drcInit = try clock.measure {
            drcSession = try IncrementalDRCSession(document: document, tech: tech)
        }
        let drc = try #require(drcSession)
        #expect(drc.currentResult.violations.isEmpty == true)

        var moved = wire
        guard case .rect(let rect) = wire.geometry else {
            Issue.record("fixture wire must be rectangular")
            return
        }
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: rect.origin.x, y: rect.origin.y + 0.02),
            size: rect.size
        ))
        var drcSamples: [Double] = []
        for _ in 0..<5 {
            let forth = try drc.apply(LayoutEditDelta(updatedShapes: [moved]))
            drcSamples.append(Self.milliseconds(forth.duration))
            let back = try drc.apply(LayoutEditDelta(updatedShapes: [wire]))
            drcSamples.append(Self.milliseconds(back.duration))
        }
        drcSamples.sort()

        var connectivitySession: LiveConnectivitySession? = nil
        let connectivityInit = try clock.measure {
            connectivitySession = try LiveConnectivitySession(document: document, tech: tech)
        }
        let connectivity = try #require(connectivitySession)
        var connectivitySamples: [Double] = []
        for _ in 0..<5 {
            let forth = try connectivity.apply(LayoutEditDelta(updatedShapes: [moved]))
            connectivitySamples.append(Self.milliseconds(forth.duration))
            let back = try connectivity.apply(LayoutEditDelta(updatedShapes: [wire]))
            connectivitySamples.append(Self.milliseconds(back.duration))
        }
        connectivitySamples.sort()

        let drcMedian = drcSamples[drcSamples.count / 2]
        let connectivityMedian = connectivitySamples[connectivitySamples.count / 2]
        func verdict(_ value: Double, _ target: Double) -> String {
            value <= target ? "MEETS" : "MISSES"
        }
        print("[bench] (\(configuration), \(shapeCount)s/\(viaCount)v) DRC init: \(String(format: "%.0f", Self.milliseconds(drcInit)))ms, connectivity init: \(String(format: "%.0f", Self.milliseconds(connectivityInit)))ms")
        print("[bench] (\(configuration)) 1M DRC wireMove median \(String(format: "%.2f", drcMedian))ms (\(verdict(drcMedian, 10)) 10ms live target)")
        print("[bench] (\(configuration)) 1M connectivity wireMove median \(String(format: "%.2f", connectivityMedian))ms (\(verdict(connectivityMedian, 10)) 10ms live target)")

        #expect(drc.commit().violations.isEmpty == true)
        #expect(drcMedian < 1_000, "1M DRC live apply regressed")
        #expect(connectivityMedian < 1_000, "1M connectivity live apply regressed")
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
