import Foundation
import Testing
import LayoutCore
import LayoutTech

@Suite("Layout conductor stack")
struct LayoutConductorStackTests {
    private let active = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
    private let poly = LayoutLayerID(name: "POLY", purpose: "drawing")
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let m3 = LayoutLayerID(name: "M3", purpose: "drawing")
    private let liCut = LayoutLayerID(name: "LICON", purpose: "cut")
    private let via1Cut = LayoutLayerID(name: "VIA1", purpose: "cut")
    private let via2Cut = LayoutLayerID(name: "VIA2", purpose: "cut")

    @Test func derivesLongestPathRanksFromViasAndContacts() throws {
        let stack = try LayoutConductorStack.derive(from: technology(
            vias: [
                via(id: "via1", cutLayer: via1Cut, bottom: m1, top: m2),
                via(id: "via2", cutLayer: via2Cut, bottom: m2, top: m3),
            ],
            contacts: [
                contact(id: "licon-active", bottom: active, top: m1),
                contact(id: "licon-poly", bottom: poly, top: m1),
            ]
        ))

        #expect(stack.rank(of: active) == 0)
        #expect(stack.rank(of: poly) == 0)
        #expect(stack.rank(of: m1) == 1)
        #expect(stack.rank(of: m2) == 2)
        #expect(stack.rank(of: m3) == 3)
        #expect(stack.topRank == 3)
    }

    @Test func rejectsTechnologyWithoutCutDefinitions() {
        #expect(throws: LayoutConductorStackError.noCutDefinitions) {
            _ = try LayoutConductorStack.derive(from: technology())
        }
    }

    @Test func rejectsSelfReferentialCutDefinition() {
        #expect(throws: LayoutConductorStackError.cyclicLayerOrder) {
            _ = try LayoutConductorStack.derive(from: technology(
                vias: [via(id: "bad-via", cutLayer: via1Cut, bottom: m1, top: m1)]
            ))
        }
    }

    private func technology(
        vias: [LayoutViaDefinition] = [],
        contacts: [LayoutContactDefinition] = []
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            layers: [active, poly, m1, m2, m3, liCut, via1Cut, via2Cut].map(layerDefinition),
            vias: vias,
            layerRules: [],
            contacts: contacts
        )
    }

    private func layerDefinition(for id: LayoutLayerID) -> LayoutLayerDefinition {
        LayoutLayerDefinition(
            id: id,
            displayName: id.name,
            gdsLayer: 1,
            gdsDatatype: 0,
            color: .gray
        )
    }

    private func via(
        id: String,
        cutLayer: LayoutLayerID,
        bottom: LayoutLayerID,
        top: LayoutLayerID
    ) -> LayoutViaDefinition {
        LayoutViaDefinition(
            id: id,
            cutLayer: cutLayer,
            topLayer: top,
            bottomLayer: bottom,
            cutSize: LayoutSize(width: 0.2, height: 0.2),
            enclosure: LayoutViaEnclosure(top: 0.05, bottom: 0.05),
            cutSpacing: 0.2
        )
    }

    private func contact(
        id: String,
        bottom: LayoutLayerID,
        top: LayoutLayerID
    ) -> LayoutContactDefinition {
        LayoutContactDefinition(
            id: id,
            cutLayer: liCut,
            bottomLayer: bottom,
            topLayer: top,
            cutSize: LayoutSize(width: 0.2, height: 0.2),
            enclosure: LayoutViaEnclosure(top: 0.05, bottom: 0.05),
            cutSpacing: 0.2
        )
    }
}
