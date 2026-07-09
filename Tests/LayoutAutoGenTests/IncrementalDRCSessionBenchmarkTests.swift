import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Live-edit latency of `IncrementalDRCSession` on the same synthetic
/// routed design the full-service benchmark uses (per-net M1 wires with
/// M2 landing pads and vias). Reports apply() latency for a sparse-layer
/// edit (M1 wire) and a dense-layer edit (M2 pad) against the full-run
/// baseline; the interactive target is 10ms, the hard regression cap is
/// deliberately generous.
@Suite("IncrementalDRCSession Benchmark", .serialized, .timeLimit(.minutes(10)))
struct IncrementalDRCSessionBenchmarkTests {

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

    /// Same construction as the full-service scale benchmark: per row one
    /// M1 wire on its own net with M2 pads and vias every third column.
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

    /// Applies `move` then its inverse repeatedly and returns the sorted
    /// per-apply latencies in milliseconds.
    private func measureMoves(
        session: IncrementalDRCSession,
        original: LayoutShape,
        moved: LayoutShape,
        rounds: Int
    ) throws -> [Double] {
        var samples: [Double] = []
        for _ in 0..<rounds {
            let forth = try session.apply(LayoutEditDelta(updatedShapes: [moved]))
            samples.append(milliseconds(forth.duration))
            let back = try session.apply(LayoutEditDelta(updatedShapes: [original]))
            samples.append(milliseconds(back.duration))
        }
        return samples.sorted()
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

    private enum BenchmarkFixtureError: Error {
        case expectedRectGeometry
        case fixtureShapeNotFound
    }

    @Test func liveApplyLatencyAtScale() throws {
        try BenchmarkExecutionGate.run {
        let rows = 80
        let cols = 80
        let document = makeDocument(rows: rows, cols: cols)
        let tech = makeTech()
        let topCell = try #require(document.cells.first)
        let clock = ContinuousClock()

        // Full-run baseline: what a non-incremental tool pays per edit.
        let service = LayoutDRCService()
        var baseline: LayoutDRCResult? = nil
        let baselineDuration = clock.measure {
            baseline = service.run(document: document, tech: tech)
        }
        #expect(baseline?.violations.isEmpty == true, "benchmark design is clean by construction")

        var session: IncrementalDRCSession? = nil
        let initDuration = try clock.measure {
            session = try IncrementalDRCSession(document: document, tech: tech)
        }
        let liveSession = try #require(session)
        #expect(liveSession.currentResult.violations.isEmpty == true)

        // Sparse-layer edit: nudge one M1 row wire by 0.02um (stays clean:
        // via enclosure margin 0.09 -> 0.07 against the 0.05 rule).
        let wire = try #require(
            topCell.shapes.first {
                $0.layer == m1 && LayoutGeometryAnalysis.boundingBox(for: $0.geometry).origin.y == 40.0
            },
            "row-40 M1 wire must exist"
        )
        let wireSamples = try measureMoves(
            session: liveSession,
            original: wire,
            moved: try shifted(wire, dy: 0.02),
            rounds: 10
        )

        // Dense-layer edit: nudge one M2 pad by 0.02um (M2 carries ~2100
        // shapes, so this exposes the per-layer recompute cost).
        let pad = try #require(
            topCell.shapes.first {
                $0.layer == m2 && {
                    let box = LayoutGeometryAnalysis.boundingBox(for: $0.geometry)
                    return box.origin.x == 41.3 && box.origin.y == 40.0
                }($0)
            },
            "row-40 col-41 M2 pad must exist"
        )
        let padSamples = try measureMoves(
            session: liveSession,
            original: pad,
            moved: try shifted(pad, dy: 0.02),
            rounds: 10
        )

        #expect(liveSession.commit().violations.isEmpty == true, "round-trip edits must end clean")

        #if DEBUG
        let interactiveMedianCap = 50.0
        let interactiveMedianCapLabel = "50ms debug cap"
        #else
        let interactiveMedianCap = 10.0
        let interactiveMedianCapLabel = "10ms release target"
        #endif
        let shapeCount = topCell.shapes.count
        let viaCount = topCell.vias.count
        func report(_ label: String, _ samples: [Double]) {
            let median = samples[samples.count / 2]
            let worst = samples.last ?? 0
            let target = median <= interactiveMedianCap ? "MEETS" : "MISSES"
            print("[bench] incremental \(label) \(shapeCount)s/\(viaCount)v: median \(String(format: "%.2f", median))ms, max \(String(format: "%.2f", worst))ms (\(target) \(interactiveMedianCapLabel))")
        }
        print("[bench] full run baseline: \(String(format: "%.1f", milliseconds(baselineDuration)))ms, session init: \(String(format: "%.1f", milliseconds(initDuration)))ms")
        report("m1WireMove", wireSamples)
        report("m2PadMove", padSamples)

        #expect(wireSamples[wireSamples.count / 2] < interactiveMedianCap, "sparse-layer live apply regressed")
        #expect(padSamples[padSamples.count / 2] < interactiveMedianCap, "dense-layer live apply regressed")
        }
    }

    /// M7 scale parity: the live verification sessions must keep their
    /// per-edit budgets on a design two orders of magnitude larger than
    /// the interactive benchmark above (~170k elements). Open cost (init)
    /// is reported alongside, since it bounds how big a document the
    /// editor can load with live verification enabled.
    @Test func liveSessionsScaleToHundredThousandElements() throws {
        try BenchmarkExecutionGate.run {
        let rows = 500
        let cols = 500
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let document = makeDocument(rows: rows, cols: cols)
        let tech = makeTech()
        let topCell = try #require(document.cells.first)
        let clock = ContinuousClock()
        let shapeCount = topCell.shapes.count
        let viaCount = topCell.vias.count

        let wire = try #require(
            topCell.shapes.first {
                $0.layer == m1 && LayoutGeometryAnalysis.boundingBox(for: $0.geometry).origin.y == 250.0
            },
            "row-250 M1 wire must exist"
        )
        let pad = try #require(
            topCell.shapes.first {
                $0.layer == m2 && {
                    let box = LayoutGeometryAnalysis.boundingBox(for: $0.geometry)
                    return box.origin.x == 251.3 && box.origin.y == 250.0
                }($0)
            },
            "row-250 col-251 M2 pad must exist"
        )

        // Incremental DRC.
        var drcSession: IncrementalDRCSession? = nil
        let drcInit = try clock.measure {
            drcSession = try IncrementalDRCSession(document: document, tech: tech)
        }
        let drc = try #require(drcSession)
        #expect(drc.currentResult.violations.isEmpty == true)
        let drcWire = try measureMoves(
            session: drc, original: wire, moved: try shifted(wire, dy: 0.02), rounds: 5
        )
        let drcPad = try measureMoves(
            session: drc, original: pad, moved: try shifted(pad, dy: 0.02), rounds: 5
        )

        // Live connectivity.
        var connectivitySession: LiveConnectivitySession? = nil
        let connectivityInit = try clock.measure {
            connectivitySession = try LiveConnectivitySession(document: document, tech: tech)
        }
        let connectivity = try #require(connectivitySession)
        var connectivitySamples: [Double] = []
        for _ in 0..<5 {
            let forth = try connectivity.apply(LayoutEditDelta(updatedShapes: [try shifted(wire, dy: 0.02)]))
            connectivitySamples.append(milliseconds(forth.duration))
            let back = try connectivity.apply(LayoutEditDelta(updatedShapes: [wire]))
            connectivitySamples.append(milliseconds(back.duration))
        }
        connectivitySamples.sort()

        func median(_ samples: [Double]) -> Double { samples[samples.count / 2] }
        func verdict(_ value: Double, _ target: Double) -> String {
            value <= target ? "MEETS" : "MISSES"
        }

        #if DEBUG
        let drcInitCap = 90_000.0
        let connectivityInitCap = 20_000.0
        let drcMedianCap = 80.0
        let connectivityMedianCap = 40.0
        let drcMedianCapLabel = "80ms debug cap"
        let connectivityMedianCapLabel = "40ms debug cap"
        #else
        let drcInitCap = 20_000.0
        let connectivityInitCap = 10_000.0
        let drcMedianCap = 10.0
        let connectivityMedianCap = 10.0
        let drcMedianCapLabel = "10ms release target"
        let connectivityMedianCapLabel = "10ms release target"
        #endif
        print("[bench] (\(configuration), \(shapeCount)s/\(viaCount)v) DRC init: \(String(format: "%.0f", milliseconds(drcInit)))ms, connectivity init: \(String(format: "%.0f", milliseconds(connectivityInit)))ms")
        print("[bench] (\(configuration)) DRC m1WireMove median \(String(format: "%.2f", median(drcWire)))ms, m2PadMove median \(String(format: "%.2f", median(drcPad)))ms (\(verdict(max(median(drcWire), median(drcPad)), drcMedianCap)) \(drcMedianCapLabel))")
        print("[bench] (\(configuration)) connectivity wireMove median \(String(format: "%.2f", median(connectivitySamples)))ms (\(verdict(median(connectivitySamples), connectivityMedianCap)) \(connectivityMedianCapLabel))")

        #expect(drc.commit().violations.isEmpty == true, "round-trip edits must end clean")

        #expect(milliseconds(drcInit) < drcInitCap, "DRC session init regressed")
        #expect(milliseconds(connectivityInit) < connectivityInitCap, "connectivity session init regressed")
        #expect(median(drcWire) < drcMedianCap, "sparse-layer live apply regressed at scale")
        #expect(median(drcPad) < drcMedianCap, "dense-layer live apply regressed at scale")
        #expect(median(connectivitySamples) < connectivityMedianCap, "connectivity live apply regressed at scale")
        }
    }

    @Test func violationAppearsAndClearsAtScale() throws {
        let document = makeDocument(rows: 80, cols: 80)
        let tech = makeTech()
        let topCell = try #require(document.cells.first)
        let session = try IncrementalDRCSession(document: document, tech: tech)
        #expect(session.currentResult.violations.isEmpty == true)

        let pad = try #require(
            topCell.shapes.first {
                $0.layer == m2 && {
                    let box = LayoutGeometryAnalysis.boundingBox(for: $0.geometry)
                    return box.origin.x == 41.3 && box.origin.y == 40.0
                }($0)
            }
        )

        // 0.05um offset against the 0.05um enclosure margin breaks the via
        // landing; the violation must appear live and clear on restore.
        let broken = try session.apply(
            LayoutEditDelta(updatedShapes: [try shifted(pad, dy: 0.05)])
        )
        #expect(!broken.result.violations.isEmpty, "enclosure break must surface immediately")

        let restored = try session.apply(LayoutEditDelta(updatedShapes: [pad]))
        #expect(restored.result.violations.isEmpty == true, "restore must clear the violation")

        // Cross-check the broken state against the full service once at
        // scale: same document, same verdict multiset.
        var mutated = document
        guard let cellIndex = mutated.cells.firstIndex(where: { $0.id == mutated.topCellID }),
              let shapeIndex = mutated.cells[cellIndex].shapes.firstIndex(where: { $0.id == pad.id }) else {
            throw BenchmarkFixtureError.fixtureShapeNotFound
        }
        mutated.cells[cellIndex].shapes[shapeIndex] = try shifted(pad, dy: 0.05)
        let rebroken = try session.apply(
            LayoutEditDelta(updatedShapes: [try shifted(pad, dy: 0.05)])
        )
        let reference = LayoutDRCService().run(document: mutated, tech: tech)
        #expect(
            IncrementalDRCEquivalenceHarness.canonicalCounts(rebroken.result.violations, excludingAntenna: true)
                == IncrementalDRCEquivalenceHarness.canonicalCounts(reference.violations, excludingAntenna: true),
            "scale spot-check: incremental snapshot must match the full run"
        )
    }
}
