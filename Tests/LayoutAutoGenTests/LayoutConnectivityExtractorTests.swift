import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Semantics of the label-free batch extraction: components from physical
/// contact (same-layer overlap and via stacking), shorts from multi-label
/// components, opens from multi-component labels with deterministic
/// MST flylines.
@Suite("LayoutConnectivityExtractor")
struct LayoutConnectivityExtractorTests {

    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let via1 = LayoutLayerID(name: "VIA1", purpose: "cut")

    private func makeTech() -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            layers: [m1, m2, via1].enumerated().map { index, id in
                LayoutLayerDefinition(
                    id: id,
                    displayName: id.name,
                    gdsLayer: index + 1,
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

    private func rect(
        layer: LayoutLayerID,
        net: UUID?,
        x: Double, y: Double, width: Double, height: Double
    ) -> LayoutShape {
        LayoutShape(
            layer: layer,
            netID: net,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: width, height: height)
            ))
        )
    }

    private func document(shapes: [LayoutShape], vias: [LayoutVia] = []) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes, vias: vias)
        return LayoutDocument(name: "connectivity-fixture", cells: [cell], topCellID: cell.id)
    }

    @Test func viaStackFormsOneNet() throws {
        let netA = UUID()
        let wire = rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4)
        let pad = rect(layer: m2, net: netA, x: 0.3, y: 0, width: 0.4, height: 0.4)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.2), netID: netA)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [wire, pad], vias: [via]),
            tech: makeTech()
        )

        #expect(analysis.nets.count == 1)
        #expect(analysis.nets.first?.shapeIDs.count == 2)
        #expect(analysis.nets.first?.viaIDs == [via.id])
        #expect(analysis.nets.first?.declaredNetIDs == [netA])
        #expect(analysis.shorts.isEmpty)
        #expect(analysis.opens.isEmpty)
    }

    @Test func stackedLayersWithoutViaAreOpenWithZeroLengthFlyline() throws {
        let netA = UUID()
        let wire = rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4)
        let pad = rect(layer: m2, net: netA, x: 0.3, y: 0, width: 0.4, height: 0.4)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [wire, pad]),
            tech: makeTech()
        )

        #expect(analysis.nets.count == 2, "plan-view overlap without a via must not conduct")
        let open = try #require(analysis.opens.first)
        #expect(analysis.opens.count == 1)
        #expect(open.netID == netA)
        #expect(open.islands.count == 2)
        let flyline = try #require(open.flylines.first)
        #expect(open.flylines.count == 1)
        #expect(flyline.length == 0, "stacked extents touch in plan view")
        #expect(flyline.start == flyline.end)
        #expect(abs(flyline.start.x - 0.5) < 1e-9, "x resolves to the overlap midpoint")
        #expect(abs(flyline.start.y - 0.2) < 1e-9, "y resolves to the overlap midpoint")
    }

    @Test func openNetYieldsMinimumSpanningFlylines() throws {
        let netA = UUID()
        let left = rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4)
        let middle = rect(layer: m1, net: netA, x: 10, y: 0, width: 1, height: 0.4)
        let right = rect(layer: m1, net: netA, x: 21, y: 0, width: 1, height: 0.4)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [left, middle, right]),
            tech: makeTech()
        )

        let open = try #require(analysis.opens.first)
        #expect(open.islands.count == 3)
        #expect(open.flylines.count == 2, "an MST over 3 islands has exactly 2 edges")

        // Gaps are 9 (left-middle), 10 (middle-right), 20 (left-right); the
        // MST must pick the two short ones regardless of island order.
        let lengths = open.flylines.map(\.length).sorted()
        #expect(abs(lengths[0] - 9) < 1e-9 && abs(lengths[1] - 10) < 1e-9)
        for flyline in open.flylines {
            #expect(abs(flyline.start.y - 0.2) < 1e-9 && abs(flyline.end.y - 0.2) < 1e-9)
            let xs = [flyline.start.x, flyline.end.x].sorted()
            if abs(flyline.length - 9) < 1e-9 {
                #expect(abs(xs[0] - 1) < 1e-9 && abs(xs[1] - 10) < 1e-9)
            } else {
                #expect(abs(xs[0] - 11) < 1e-9 && abs(xs[1] - 21) < 1e-9)
            }
        }
    }

    @Test func unlabeledBridgeShortsTwoNets() throws {
        let netA = UUID()
        let netB = UUID()
        let wireA = rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4)
        let wireB = rect(layer: m1, net: netB, x: 2, y: 0, width: 1, height: 0.4)
        let bridge = rect(layer: m1, net: nil, x: 0.8, y: 0, width: 1.4, height: 0.4)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [wireA, wireB, bridge]),
            tech: makeTech()
        )

        #expect(analysis.nets.count == 1)
        let short = try #require(analysis.shorts.first)
        #expect(analysis.shorts.count == 1)
        #expect(Set(short.netIDs) == [netA, netB])
        #expect(short.shapeIDs.count == 3, "the unlabeled bridge is part of the shorting conductor")
        #expect(analysis.opens.isEmpty)
    }

    @Test func viaMediatedShortAcrossLayers() throws {
        let netA = UUID()
        let netB = UUID()
        let wireA = rect(layer: m1, net: netA, x: 0, y: 0, width: 2, height: 0.4)
        let padB = rect(layer: m2, net: netB, x: 0.3, y: 0, width: 0.4, height: 0.4)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.2), netID: nil)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [wireA, padB], vias: [via]),
            tech: makeTech()
        )

        let short = try #require(analysis.shorts.first)
        #expect(Set(short.netIDs) == [netA, netB])
        #expect(short.viaIDs == [via.id])
    }

    @Test func floatingMetalIsNeitherShortNorOpen() throws {
        let floating = rect(layer: m1, net: nil, x: 0, y: 0, width: 1, height: 0.4)

        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: [floating]),
            tech: makeTech()
        )

        #expect(analysis.nets.count == 1)
        #expect(analysis.nets.first?.declaredNetIDs.isEmpty == true)
        #expect(analysis.shorts.isEmpty)
        #expect(analysis.opens.isEmpty)
    }

    @Test func emptyDesignYieldsEmptyAnalysis() throws {
        let analysis = try LayoutConnectivityExtractor().extract(
            document: document(shapes: []),
            tech: makeTech()
        )
        #expect(analysis == .empty)
    }

    @Test func missingTargetCellThrows() {
        let empty = LayoutDocument(name: "empty", cells: [], topCellID: nil)
        #expect(throws: LayoutConnectivityExtractionError.targetCellNotFound) {
            try LayoutConnectivityExtractor().extract(document: empty, tech: makeTech())
        }
    }
}
