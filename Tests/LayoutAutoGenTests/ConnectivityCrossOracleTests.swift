import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Cross-checks the extraction engine against the DRC deck's declared-net
/// connectivity checks. The two oracles answer different questions — the
/// DRC short check compares declared labels pairwise, the extractor
/// compares physical conductor pieces — so the contract is containment,
/// not equality:
///
/// - every pairwise overlap short is inside some extracted short, and the
///   extractor additionally sees via-mediated and unlabeled-bridge shorts;
/// - every extracted open is also a DRC open, and the two agree exactly
///   when the net's connectivity runs through its own labeled geometry.
@Suite("Connectivity cross-oracle")
struct ConnectivityCrossOracleTests {

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
        return LayoutDocument(name: "cross-oracle-fixture", cells: [cell], topCellID: cell.id)
    }

    @Test func pairwiseShortsAreContainedInExtractedShorts() throws {
        let netA = UUID()
        let netB = UUID()
        let doc = document(shapes: [
            rect(layer: m1, net: netA, x: 0, y: 0, width: 1.2, height: 0.4),
            rect(layer: m1, net: netB, x: 1.0, y: 0, width: 1.2, height: 0.4),
        ])
        let tech = makeTech()

        let drcShorts = LayoutDRCService().run(document: doc, tech: tech)
            .violations.filter { $0.kind == .overlapShort }
        let extracted = try LayoutConnectivityExtractor().extract(document: doc, tech: tech)

        #expect(drcShorts.count == 1, "fixture must trip the pairwise check")
        for violation in drcShorts {
            let pair = Set(violation.netIDs)
            #expect(
                extracted.shorts.contains { pair.isSubset(of: Set($0.netIDs)) },
                "every pairwise short must be inside an extracted short"
            )
        }
        #expect(extracted.shorts.count == 1)
    }

    @Test func viaMediatedShortIsInvisibleToThePairwiseCheck() throws {
        let netA = UUID()
        let netB = UUID()
        let doc = document(
            shapes: [
                rect(layer: m1, net: netA, x: 0, y: 0, width: 2, height: 0.4),
                rect(layer: m2, net: netB, x: 0.3, y: 0, width: 0.4, height: 0.4),
            ],
            vias: [LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.2), netID: nil)]
        )
        let tech = makeTech()

        let drcShorts = LayoutDRCService().run(document: doc, tech: tech)
            .violations.filter { $0.kind == .overlapShort }
        let extracted = try LayoutConnectivityExtractor().extract(document: doc, tech: tech)

        #expect(drcShorts.isEmpty, "different layers never trip the same-layer pairwise check")
        #expect(extracted.shorts.count == 1, "the extractor must see the short through the via")
        #expect(Set(extracted.shorts.first?.netIDs ?? []) == [netA, netB])
    }

    @Test func unlabeledBridgeShortIsInvisibleToThePairwiseCheck() throws {
        let netA = UUID()
        let netB = UUID()
        let doc = document(shapes: [
            rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4),
            rect(layer: m1, net: netB, x: 2, y: 0, width: 1, height: 0.4),
            rect(layer: m1, net: nil, x: 0.8, y: 0, width: 1.4, height: 0.4),
        ])
        let tech = makeTech()

        let drcShorts = LayoutDRCService().run(document: doc, tech: tech)
            .violations.filter { $0.kind == .overlapShort }
        let extracted = try LayoutConnectivityExtractor().extract(document: doc, tech: tech)

        #expect(drcShorts.isEmpty, "nil-net contacts never trip the pairwise check")
        #expect(extracted.shorts.count == 1, "the extractor must see the short through the bridge")
        #expect(Set(extracted.shorts.first?.netIDs ?? []) == [netA, netB])
    }

    @Test func extractedOpensMatchDRCOpensOnFullyLabeledDesign() throws {
        // The rich fixture's connectivity runs entirely through labeled
        // geometry, so the two oracles must agree net for net (the child
        // cell's internal net is instantiated twice disjointly and is the
        // only open).
        let fixture = IncrementalDRCEquivalenceHarness.makeRichFixture()

        let drcOpenNets = Set(
            LayoutDRCService().run(document: fixture.document, tech: fixture.tech)
                .violations.filter { $0.kind == .disconnectedOpen }
                .flatMap(\.netIDs)
        )
        let extracted = try LayoutConnectivityExtractor().extract(
            document: fixture.document,
            tech: fixture.tech
        )

        #expect(!drcOpenNets.isEmpty, "the twice-instantiated child net must be open")
        #expect(Set(extracted.opens.map(\.netID)) == drcOpenNets)
        for open in extracted.opens {
            #expect(open.islands.count == 2, "one island per child instance")
            #expect(open.flylines.count == 1)
        }
    }

    @Test func unlabeledBridgeMakesExtractorStricterSubsetOfDRCOpens() throws {
        // Net A's two labeled pieces connect only through unlabeled metal.
        // The DRC open check walks the declared subgraph and calls it
        // open; the extractor sees the physical conductor and does not.
        // The containment direction must never flip: extracted opens are
        // always DRC opens too.
        let netA = UUID()
        let doc = document(shapes: [
            rect(layer: m1, net: netA, x: 0, y: 0, width: 1, height: 0.4),
            rect(layer: m1, net: netA, x: 2, y: 0, width: 1, height: 0.4),
            rect(layer: m1, net: nil, x: 0.8, y: 0, width: 1.4, height: 0.4),
        ])
        let tech = makeTech()

        let drcOpenNets = Set(
            LayoutDRCService().run(document: doc, tech: tech)
                .violations.filter { $0.kind == .disconnectedOpen }
                .flatMap(\.netIDs)
        )
        let extracted = try LayoutConnectivityExtractor().extract(document: doc, tech: tech)

        #expect(drcOpenNets == [netA], "the declared subgraph alone is disconnected")
        #expect(extracted.opens.isEmpty, "physically the net is one conductor piece")
        #expect(Set(extracted.opens.map(\.netID)).isSubset(of: drcOpenNets))
    }
}
