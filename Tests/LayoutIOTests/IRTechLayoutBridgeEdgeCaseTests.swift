import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("IRTechLayoutBridge Edge Cases")
struct IRTechLayoutBridgeEdgeCaseTests {

    private let bridge = IRTechLayoutBridge()

    // MARK: - Layer with nil fillPattern defaults to solid

    @Test func nilFillPatternDefaultsSolid() {
        let lib = IRTechLibrary(
            layers: [
                IRTechLayerDef(name: "M1", type: .routing, gdsLayer: 1)
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.layers[0].fillPattern == .solid)
    }

    // MARK: - Layer with visibleByDefault = false

    @Test func visibleByDefaultFalse() {
        let lib = IRTechLibrary(
            layers: [
                IRTechLayerDef(name: "HIDDEN", type: .implant, gdsLayer: 99, visibleByDefault: false)
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.layers[0].visibleByDefault == false)
    }

    // MARK: - Layer with nil gdsLayer/gdsDatatype defaults to 0

    @Test func nilGdsLayerDefaultsZero() {
        let lib = IRTechLibrary(
            layers: [
                IRTechLayerDef(name: "NOLAYER", type: .masterslice)
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.layers[0].gdsLayer == 0)
        #expect(tech.layers[0].gdsDatatype == 0)
    }

    // MARK: - Via with nil cutWidth (only one nil)

    @Test func viaWithOnlyWidthNil() {
        let lib = IRTechLibrary(
            vias: [
                IRTechViaDef(
                    name: "V1",
                    cutLayerName: "CUT",
                    topLayerName: "M2",
                    bottomLayerName: "M1",
                    cutHeight: 0.1
                )
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        // cutWidth is nil → fallback size
        #expect(tech.vias[0].cutSize.width == 0.1)
        #expect(tech.vias[0].cutSize.height == 0.1)
    }

    // MARK: - Via with nil enclosure defaults to zero

    @Test func viaWithNilEnclosure() {
        let lib = IRTechLibrary(
            vias: [
                IRTechViaDef(
                    name: "V1",
                    cutLayerName: "CUT",
                    topLayerName: "M2",
                    bottomLayerName: "M1",
                    cutWidth: 0.1,
                    cutHeight: 0.1
                )
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.vias[0].enclosure.top == 0)
        #expect(tech.vias[0].enclosure.bottom == 0)
    }

    // MARK: - Via with nil spacing defaults to zero

    @Test func viaWithNilSpacing() {
        let lib = IRTechLibrary(
            vias: [
                IRTechViaDef(
                    name: "V1",
                    cutLayerName: "CUT",
                    topLayerName: "M2",
                    bottomLayerName: "M1",
                    cutWidth: 0.1,
                    cutHeight: 0.1
                )
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.vias[0].cutSpacing == 0)
    }

    // MARK: - Mixed valid/invalid vias

    @Test func mixedValidInvalidVias() {
        let lib = IRTechLibrary(
            vias: [
                IRTechViaDef(name: "GOOD", cutLayerName: "CUT", topLayerName: "M2", bottomLayerName: "M1"),
                IRTechViaDef(name: "BAD", cutLayerName: "", topLayerName: "M2", bottomLayerName: "M1"),
                IRTechViaDef(name: "ALSO_GOOD", cutLayerName: "CUT2", topLayerName: "M3", bottomLayerName: "M2"),
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.vias.count == 2)
        #expect(tech.vias[0].id == "GOOD")
        #expect(tech.vias[1].id == "ALSO_GOOD")
    }

    // MARK: - Design rule with nil density fields

    @Test func designRuleNilDensities() {
        let lib = IRTechLibrary(
            designRules: [
                IRTechDesignRule(layerName: "M1", minWidth: 0.14)
            ]
        )
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.layerRules.count == 1)
        #expect(tech.layerRules[0].minWidth == 0.14)
        #expect(tech.layerRules[0].minSpacing == 0)
        #expect(tech.layerRules[0].minArea == 0)
        #expect(tech.layerRules[0].minDensity == 0)
        #expect(tech.layerRules[0].maxDensity == 1)
    }

    // MARK: - inferPurposeFromName for unknown layer

    @Test func purposeInferenceForUnknownName() {
        let lib = IRTechLibrary(
            designRules: [
                IRTechDesignRule(layerName: "UNKNOWN_LAYER", minWidth: 0.1)
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.layerRules[0].layerID.purpose == "drawing")
    }

    @Test func purposeInferenceForViaName() {
        let lib = IRTechLibrary(
            designRules: [
                IRTechDesignRule(layerName: "VIA1", minSpacing: 0.17)
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.layerRules[0].layerID.purpose == "cut")
    }

    // MARK: - All fill patterns round-trip through export

    @Test func allFillPatternsExport() {
        let patterns: [LayoutFillPattern] = [
            .solid, .forwardDiagonal, .backwardDiagonal, .crosshatch,
            .horizontal, .vertical, .grid, .dots
        ]

        for (i, pattern) in patterns.enumerated() {
            let tech = LayoutTechDatabase(
                layers: [
                    LayoutLayerDefinition(
                        id: LayoutLayerID(name: "L\(i)", purpose: "drawing"),
                        displayName: "L\(i)",
                        gdsLayer: i,
                        gdsDatatype: 0,
                        color: .gray,
                        fillPattern: pattern
                    )
                ],
                vias: [],
                layerRules: []
            )

            let exported = bridge.exportTechLibrary(tech)
            let reimported = bridge.importTechLibrary(exported)
            #expect(reimported.layers[0].fillPattern == pattern)
        }
    }

    // MARK: - Fallback color for different layer numbers

    @Test func fallbackColorDifferentLayers() {
        let lib = IRTechLibrary(
            layers: [
                IRTechLayerDef(name: "L0", type: .routing, gdsLayer: 0),
                IRTechLayerDef(name: "L1", type: .routing, gdsLayer: 1),
                IRTechLayerDef(name: "L100", type: .routing, gdsLayer: 100),
                IRTechLayerDef(name: "L360", type: .routing, gdsLayer: 360),
            ]
        )
        let tech = bridge.importTechLibrary(lib)

        // All should have valid RGB values
        for layer in tech.layers {
            #expect(layer.color.red >= 0 && layer.color.red <= 1)
            #expect(layer.color.green >= 0 && layer.color.green <= 1)
            #expect(layer.color.blue >= 0 && layer.color.blue <= 1)
        }

        // Different layers should get different colors
        #expect(tech.layers[0].color != tech.layers[1].color)
    }

    // MARK: - Grid calculation from dbuPerMicron

    @Test func gridFromDBU() {
        let lib1 = IRTechLibrary(dbuPerMicron: 1000)
        let tech1 = bridge.importTechLibrary(lib1)
        #expect(tech1.grid == 0.001)

        let lib2 = IRTechLibrary(dbuPerMicron: 100)
        let tech2 = bridge.importTechLibrary(lib2)
        #expect(tech2.grid == 0.01)
    }
}
