import Foundation
import Testing
import LayoutCore
import LayoutVerify
import LayoutEditor

/// M6 scale target: planning a frame over a 1,000,000-shape flat layout
/// must stay interactive at every zoom. Fit-all zoom must take the
/// budget fallback (per-cell density aggregates, no shape visits);
/// a zoomed-in viewport must cull down to the visible handful; and a
/// single-shape edit must update the index incrementally — never by
/// rebuilding.
///
/// Honest targets are printed per run (with the build configuration,
/// since debug carries a constant-factor penalty); the #expect caps are
/// deliberately generous so regressions fail loudly without flaking.
@Suite("LayoutRenderIndex Scale Benchmark", .serialized, .timeLimit(.minutes(10)))
struct LayoutRenderIndexScaleBenchmarkTests {

    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    /// `side`² unit squares on a 2 µm pitch: side 1000 → 1M shapes over
    /// a 1999 × 1999 µm extent.
    private func makeShapes(side: Int) -> [LayoutShape] {
        var shapes: [LayoutShape] = []
        shapes.reserveCapacity(side * side)
        for row in 0..<side {
            let y = Double(row) * 2
            for col in 0..<side {
                shapes.append(LayoutShape(
                    layer: m1,
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: Double(col) * 2, y: y),
                        size: LayoutSize(width: 1, height: 1)
                    ))
                ))
            }
        }
        return shapes
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    @Test func millionShapePlanningStaysInteractive() throws {
        let side = 1000
        let options = LayoutRenderPlan.Options()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let shapeCount = side * side
        let clock = ContinuousClock()
        let shapes = makeShapes(side: side)

        // One-time index build — the cost of opening the document.
        var built: LayoutRenderIndex? = nil
        let buildDuration = clock.measure {
            built = LayoutRenderIndex(shapes: shapes)
        }
        var index = try #require(built)
        #expect(index.count == shapeCount)

        // Fit-all zoom: a 1000 px canvas over the whole extent. Visiting
        // every shape would blow the visit budget, so the plan must take
        // the cell-aggregate fallback and say so in its stats.
        let extent = Double(side) * 2 - 1
        let fitViewport = LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: extent, height: extent)
        )
        var fitPlan: LayoutRenderPlan? = nil
        let fitDuration = clock.measure {
            fitPlan = index.plan(
                viewport: fitViewport,
                pixelsPerMicron: 1000 / extent,
                options: options
            )
        }
        let fit = try #require(fitPlan)
        #expect(fit.stats.usedCellAggregates, "a fit-all frame over the budget must fall back to aggregates")
        #expect(fit.stats.totalShapes == shapeCount)
        #expect(fit.stats.aggregatedCount >= shapeCount, "every shape-cell incidence is accounted for")
        #expect(fit.batches.isEmpty)
        #expect(!fit.aggregates.isEmpty)
        #expect(fit.aggregates.allSatisfy { $0.density > 0 && $0.density <= 1 })

        // Zoomed in: viewport (0,0)–(19,19) at 50 px/µm holds exactly the
        // 10 × 10 grid corner (columns and rows 0, 2, …, 18), every shape
        // 50 px → full tier, and the remaining shapes are culled by the
        // grid without being visited.
        let zoomViewport = LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 19, height: 19)
        )
        var zoomPlan: LayoutRenderPlan? = nil
        let zoomDuration = clock.measure {
            zoomPlan = index.plan(
                viewport: zoomViewport,
                pixelsPerMicron: 50,
                options: options
            )
        }
        let zoom = try #require(zoomPlan)
        #expect(zoom.stats.usedCellAggregates == false)
        #expect(zoom.stats.fullCount == 100)
        #expect(zoom.stats.boxCount == 0)
        #expect(zoom.stats.aggregatedCount == 0)

        // Live edit: move one corner shape back and forth. apply() must
        // be local to the touched cells — never a rebuild.
        let original = shapes[0]
        var moved = original
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 0.5, y: 0.5),
            size: LayoutSize(width: 1, height: 1)
        ))
        var applySamples: [Double] = []
        for _ in 0..<50 {
            let forth = clock.measure {
                index.apply(LayoutEditDelta(updatedShapes: [moved]))
            }
            applySamples.append(milliseconds(forth))
            let back = clock.measure {
                index.apply(LayoutEditDelta(updatedShapes: [original]))
            }
            applySamples.append(milliseconds(back))
        }
        applySamples.sort()
        let applyMedian = applySamples[applySamples.count / 2]
        let applyWorst = applySamples.last ?? 0

        // The round-tripped index still plans the same corner.
        let after = index.plan(viewport: zoomViewport, pixelsPerMicron: 50, options: options)
        #expect(after.stats.fullCount == 100, "edits must leave no residue in the index")

        let buildMs = milliseconds(buildDuration)
        let fitMs = milliseconds(fitDuration)
        let zoomMs = milliseconds(zoomDuration)
        func verdict(_ value: Double, _ target: Double) -> String {
            value <= target ? "MEETS" : "MISSES"
        }
        print("[bench] (\(configuration), \(shapeCount) shapes) renderIndex build: \(String(format: "%.0f", buildMs))ms (\(verdict(buildMs, 5000)) 5s open target)")
        print("[bench] (\(configuration)) fit-all plan (aggregate fallback, \(fit.aggregates.count) tiles): \(String(format: "%.1f", fitMs))ms (\(verdict(fitMs, 100)) 100ms frame target)")
        print("[bench] (\(configuration)) zoomed-in plan (100 of \(shapeCount) shapes): \(String(format: "%.2f", zoomMs))ms (\(verdict(zoomMs, 16)) 16ms frame target)")
        print("[bench] (\(configuration)) single-shape apply: median \(String(format: "%.3f", applyMedian))ms, max \(String(format: "%.3f", applyWorst))ms (\(verdict(applyMedian, 1)) 1ms live target)")

        // Hard regression caps with generous headroom over the observed
        // numbers for each configuration.
        #expect(buildMs < 60_000, "index build regressed")
        #expect(fitMs < 2_000, "fit-all aggregate plan regressed")
        #expect(zoomMs < 250, "zoomed-in culled plan regressed")
        #expect(applyMedian < 10, "single-shape apply regressed")
    }
}
