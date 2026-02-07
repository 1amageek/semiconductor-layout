import Testing
import Foundation
import LayoutCore
import LayoutTech
import TechIR
@testable import LayoutIO

@Suite("IRTechLayoutBridge")
struct IRTechLayoutBridgeTests {

    private let bridge = IRTechLayoutBridge()

    private func sampleIRTechLibrary() -> IRTechLibrary {
        IRTechLibrary(
            name: "test_process",
            dbuPerMicron: 1000,
            layers: [
                IRTechLayerDef(
                    name: "ACTIVE",
                    type: .masterslice,
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: IRTechColor(red: 0.25, green: 0.72, blue: 0.25),
                    fillPattern: .solid,
                    visibleByDefault: true
                ),
                IRTechLayerDef(
                    name: "M1",
                    type: .routing,
                    gdsLayer: 3,
                    gdsDatatype: 0,
                    direction: .horizontal,
                    spacing: 0.14,
                    color: IRTechColor(red: 0.12, green: 0.25, blue: 0.54),
                    fillPattern: .forwardDiagonal,
                    visibleByDefault: true
                ),
                IRTechLayerDef(
                    name: "CONT",
                    type: .cut,
                    gdsLayer: 4,
                    gdsDatatype: 0,
                    color: IRTechColor(red: 0.5, green: 0.5, blue: 0.5),
                    fillPattern: .crosshatch
                ),
                IRTechLayerDef(
                    name: "M2",
                    type: .routing,
                    gdsLayer: 6,
                    gdsDatatype: 0,
                    direction: .vertical,
                    color: IRTechColor(red: 0.54, green: 0.35, blue: 0.09),
                    fillPattern: .backwardDiagonal
                ),
            ],
            vias: [
                IRTechViaDef(
                    name: "VIA1",
                    cutLayerName: "CONT",
                    topLayerName: "M2",
                    bottomLayerName: "M1",
                    cutWidth: 0.1,
                    cutHeight: 0.1,
                    enclosure: IRTechEnclosureValues(overhang1: 0.05, overhang2: 0.04),
                    spacing: 0.12
                )
            ],
            designRules: [
                IRTechDesignRule(layerName: "M1", minWidth: 0.14, minSpacing: 0.14, minArea: 0.058)
            ],
            enclosureRules: [
                IRTechEnclosureRule(outerLayerName: "M1", innerLayerName: "CONT", minEnclosure: 0.05)
            ],
            antennaRules: [
                IRTechAntennaRule(layerName: "M1", maxRatio: 400)
            ]
        )
    }

    // MARK: - Import Tests

    @Test func importLayers() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.layers.count == 4)
        #expect(tech.units.dbuPerMicron == 1000)

        let active = tech.layers[0]
        #expect(active.id.name == "ACTIVE")
        #expect(active.id.purpose == "drawing")
        #expect(active.gdsLayer == 1)
        #expect(active.gdsDatatype == 0)
        #expect(active.fillPattern == .solid)
        #expect(active.visibleByDefault == true)

        let m1 = tech.layers[1]
        #expect(m1.id.name == "M1")
        #expect(m1.preferredDirection == .horizontal)
        #expect(m1.fillPattern == .forwardDiagonal)

        let cont = tech.layers[2]
        #expect(cont.id.name == "CONT")
        #expect(cont.id.purpose == "cut")
        #expect(cont.fillPattern == .crosshatch)

        let m2 = tech.layers[3]
        #expect(m2.preferredDirection == .vertical)
    }

    @Test func importVias() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.vias.count == 1)
        let via = tech.vias[0]
        #expect(via.id == "VIA1")
        #expect(via.cutLayer.name == "CONT")
        #expect(via.cutLayer.purpose == "cut")
        #expect(via.topLayer.name == "M2")
        #expect(via.bottomLayer.name == "M1")
        #expect(via.cutSize.width == 0.1)
        #expect(via.cutSize.height == 0.1)
        #expect(via.enclosure.top == 0.05)
        #expect(via.enclosure.bottom == 0.04)
        #expect(via.cutSpacing == 0.12)
    }

    @Test func importDesignRules() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.layerRules.count == 1)
        let rule = tech.layerRules[0]
        #expect(rule.layerID.name == "M1")
        #expect(rule.minWidth == 0.14)
        #expect(rule.minSpacing == 0.14)
        #expect(rule.minArea == 0.058)
    }

    @Test func importEnclosureRules() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.enclosureRules.count == 1)
        #expect(tech.enclosureRules[0].outerLayer.name == "M1")
        #expect(tech.enclosureRules[0].innerLayer.name == "CONT")
        #expect(tech.enclosureRules[0].minEnclosure == 0.05)
    }

    @Test func importAntennaRules() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.antennaRules.count == 1)
        #expect(tech.antennaRules[0].layerID.name == "M1")
        #expect(tech.antennaRules[0].maxRatio == 400)
    }

    @Test func importEmptyLibrary() {
        let lib = IRTechLibrary()
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.layers.isEmpty)
        #expect(tech.vias.isEmpty)
        #expect(tech.layerRules.isEmpty)
        #expect(tech.antennaRules.isEmpty)
        #expect(tech.enclosureRules.isEmpty)
    }

    // MARK: - Export Tests

    @Test func exportRoundTrip() {
        let lib = sampleIRTechLibrary()
        let tech = bridge.importTechLibrary(lib)
        let exported = bridge.exportTechLibrary(tech, name: "round_trip")

        #expect(exported.name == "round_trip")
        #expect(exported.dbuPerMicron == 1000)
        #expect(exported.layers.count == 4)
        #expect(exported.layers[0].name == "ACTIVE")
        #expect(exported.layers[1].name == "M1")
        #expect(exported.layers[1].direction == .horizontal)
        #expect(exported.vias.count == 1)
        #expect(exported.vias[0].name == "VIA1")
        #expect(exported.vias[0].cutLayerName == "CONT")
        #expect(exported.designRules.count == 1)
        #expect(exported.designRules[0].minWidth == 0.14)
        #expect(exported.enclosureRules.count == 1)
        #expect(exported.antennaRules.count == 1)
    }

    // MARK: - Color Fallback

    @Test func importLayerWithoutColor() {
        let lib = IRTechLibrary(
            layers: [
                IRTechLayerDef(name: "NOIMPLANT", type: .implant, gdsLayer: 99)
            ]
        )
        let tech = bridge.importTechLibrary(lib)

        #expect(tech.layers.count == 1)
        let layer = tech.layers[0]
        // Should have a fallback color (not zero)
        #expect(layer.color.red >= 0 && layer.color.red <= 1)
        #expect(layer.color.green >= 0 && layer.color.green <= 1)
        #expect(layer.color.blue >= 0 && layer.color.blue <= 1)
    }

    // MARK: - Via without cut layer

    @Test func importViaWithEmptyCutLayer() {
        let lib = IRTechLibrary(
            vias: [
                IRTechViaDef(name: "BAD_VIA", cutLayerName: "", topLayerName: "M2", bottomLayerName: "M1")
            ]
        )
        let tech = bridge.importTechLibrary(lib)
        #expect(tech.vias.isEmpty)
    }
}
