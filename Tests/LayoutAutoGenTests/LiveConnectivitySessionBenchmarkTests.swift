import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Live-edit latency of `LiveConnectivitySession` on the same synthetic
/// routed design the DRC benchmarks use (per-net M1 wires with M2 landing
/// pads and vias). Reports apply() latency for a connectivity-neutral
/// nudge and for a disconnect/reconnect cycle against the batch
/// extraction baseline; the interactive target is 10ms, the hard
/// regression cap is deliberately generous.
@Suite("LiveConnectivitySession Benchmark", .serialized, .timeLimit(.minutes(10)))
struct LiveConnectivitySessionBenchmarkTests {

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
            layerRules: []
        )
    }

    /// Same construction as the DRC scale benchmark: per row one M1 wire
    /// on its own net with M2 pads and vias every third column.
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

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    private enum BenchmarkFixtureError: Error {
        case expectedRectGeometry
        case fixtureShapeNotFound
    }

    private func shifted(_ shape: LayoutShape, dy: Double) throws -> LayoutShape {
        guard case .rect(let rect) = shape.geometry else {
            throw BenchmarkFixtureError.expectedRectGeometry
        }
        var moved = shape
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: rect.origin.x, y: rect.origin.y + dy),
            size: rect.size
        ))
        return moved
    }

    @Test func liveApplyLatencyAtScale() throws {
        try BenchmarkExecutionGate.run {
        let document = makeDocument(rows: 80, cols: 80)
        let tech = makeTech()
        let topCell = try #require(document.cells.first)
        let clock = ContinuousClock()

        // Batch baseline: what a non-incremental extraction pays per edit.
        let extractor = LayoutConnectivityExtractor()
        var baseline: ConnectivityAnalysis? = nil
        let baselineDuration = try clock.measure {
            baseline = try extractor.extract(document: document, tech: tech)
        }
        #expect(baseline?.opens.isEmpty == true && baseline?.shorts.isEmpty == true,
                "benchmark design is clean by construction")
        #expect(baseline?.nets.count == 80, "one conductor piece per row net")

        var sessionOrNil: LiveConnectivitySession? = nil
        let initDuration = try clock.measure {
            sessionOrNil = try LiveConnectivitySession(document: document, tech: tech)
        }
        let session = try #require(sessionOrNil)

        let pad = try #require(
            topCell.shapes.first {
                $0.layer == m2 && {
                    let box = LayoutGeometryAnalysis.boundingBox(for: $0.geometry)
                    return box.origin.x == 41.3 && box.origin.y == 40.0
                }($0)
            },
            "row-40 col-41 M2 pad must exist"
        )

        // Neutral nudge: 0.02um keeps the via landed, so the partition is
        // re-derived for one conductor piece without changing verdicts.
        var nudgeSamples: [Double] = []
        for _ in 0..<10 {
            let forth = try session.apply(LayoutEditDelta(updatedShapes: [try shifted(pad, dy: 0.02)]))
            nudgeSamples.append(milliseconds(forth.duration))
            #expect(forth.analysis.opens.isEmpty)
            let back = try session.apply(LayoutEditDelta(updatedShapes: [pad]))
            nudgeSamples.append(milliseconds(back.duration))
        }
        nudgeSamples.sort()

        // Disconnect/reconnect: 1.0um strands the pad (open appears), the
        // restore heals it — the verdict must flip both ways live.
        var cycleSamples: [Double] = []
        for _ in 0..<10 {
            let broken = try session.apply(LayoutEditDelta(updatedShapes: [try shifted(pad, dy: 1.0)]))
            cycleSamples.append(milliseconds(broken.duration))
            #expect(broken.analysis.opens.count == 1, "stranding the pad must open its net")
            let healed = try session.apply(LayoutEditDelta(updatedShapes: [pad]))
            cycleSamples.append(milliseconds(healed.duration))
            #expect(healed.analysis.opens.isEmpty, "restoring the pad must close the open")
        }
        cycleSamples.sort()

        let shapeCount = topCell.shapes.count
        let viaCount = topCell.vias.count
        func report(_ label: String, _ samples: [Double]) {
            let median = samples[samples.count / 2]
            let worst = samples.last ?? 0
            let target = median <= 10 ? "MEETS" : "MISSES"
            print("[bench] connectivity \(label) \(shapeCount)s/\(viaCount)v: median \(String(format: "%.2f", median))ms, max \(String(format: "%.2f", worst))ms (\(target) 10ms live target)")
        }
        print("[bench] batch extraction baseline: \(String(format: "%.1f", milliseconds(baselineDuration)))ms, session init: \(String(format: "%.1f", milliseconds(initDuration)))ms")
        report("padNudge", nudgeSamples)
        report("openCloseCycle", cycleSamples)

        #expect(nudgeSamples[nudgeSamples.count / 2] < 10, "neutral-edit live apply missed the interactive target")
        #expect(cycleSamples[cycleSamples.count / 2] < 10, "open/close live apply missed the interactive target")
        }
    }
}
