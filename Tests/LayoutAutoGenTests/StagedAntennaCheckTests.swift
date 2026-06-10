import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

/// Staged antenna model: every test states which etch stage it exercises
/// and why the connectivity that exists at that stage produces (or avoids)
/// a violation.
@Suite("Staged Antenna Check")
struct StagedAntennaCheckTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let via1 = LayoutLayerID(name: "VIA1", purpose: "cut")

    // MARK: - PAR at the rule layer's own stage

    @Test func gateConnectedLargeM1StrapViolatesAtM1Stage() {
        let net = UUID()
        let gate = gatePin()
        // 1.0 x 0.5 = 0.5 um^2 against a 0.01 um^2 gate: ratio 50 > 10.
        let strap = m1Rect(x: -0.05, y: -0.05, width: 1.0, height: 0.5, netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [strap], pins: [gate]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        let violation = violations.first
        #expect(violation?.ruleID == "antenna.M1.drawing.maxRatio")
        #expect(abs((violation?.measured ?? 0) - 50) < 1)
        #expect(violation?.required == 10)
        #expect(violation?.shapeIDs == [strap.id])
        #expect(violation?.pinIDs == [gate.id])
        #expect(violation?.netIDs == [net])
    }

    @Test func diffusionTieDischargesTheGateNode() {
        let gate = gatePin()
        let strap = m1Rect(x: -0.05, y: -0.05, width: 1.0, height: 0.5)
        // A source-role pin on the same component is a discharge path: the
        // charge bleeds through the diffusion instead of the gate oxide.
        let tie = LayoutPin(
            name: "source",
            position: LayoutPoint(x: 0.5, y: 0.2),
            size: LayoutSize(width: 0.1, height: 0.1),
            layer: m1,
            role: .source
        )

        let result = LayoutDRCService().run(
            document: document(shapes: [strap], pins: [gate, tie]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        #expect(!result.violations.contains { $0.kind == .antenna })
    }

    // MARK: - Staged connectivity

    @Test func upperLayerBridgeIsolatesLowerStageArea() {
        let gate = gatePin()
        // Short stub at the gate, large wire beyond a gap, reconnected only
        // through M2. At the M1 etch stage M2 does not exist, so the gate
        // sees just the stub; at the M2 stage only M2 area counts for PAR.
        let stub = m1Rect(x: -0.05, y: -0.05, width: 0.1, height: 0.1)
        let farWire = m1Rect(x: 0.3, y: -0.25, width: 2.0, height: 0.5)
        let bridge = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.05, y: -0.03),
                size: LayoutSize(width: 1.3, height: 0.06)
            ))
        )
        let stubVia = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0, y: 0))
        let farVia = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1.0, y: 0))

        let result = LayoutDRCService().run(
            document: document(shapes: [stub, farWire, bridge], vias: [stubVia, farVia], pins: [gate]),
            tech: antennaTech(rules: [
                LayoutAntennaRule(layerID: m1, maxRatio: 10),
                LayoutAntennaRule(layerID: m2, maxRatio: 10),
            ])
        )

        #expect(!result.violations.contains { $0.kind == .antenna })
    }

    @Test func topLayerAreaViolatesAtItsOwnStage() {
        let gate = gatePin()
        let stub = m1Rect(x: -0.05, y: -0.05, width: 0.1, height: 0.1)
        // 2.0 x 0.5 = 1.0 um^2 of M2: ratio 100 > 10 at the M2 etch stage.
        let plate = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.05, y: -0.25),
                size: LayoutSize(width: 2.0, height: 0.5)
            ))
        )
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0, y: 0))

        let result = LayoutDRCService().run(
            document: document(shapes: [stub, plate], vias: [via], pins: [gate]),
            tech: antennaTech(rules: [
                LayoutAntennaRule(layerID: m1, maxRatio: 10),
                LayoutAntennaRule(layerID: m2, maxRatio: 10),
            ])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.M2.drawing.maxRatio")
        #expect(abs((violations.first?.measured ?? 0) - 100) < 1)
    }

    @Test func dischargeOnlyCountsWhenFabricated() {
        let gate = gatePin()
        let strap = m1Rect(x: -0.05, y: -0.05, width: 1.0, height: 0.5)
        let m2Wire = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.45, y: 0.15),
                size: LayoutSize(width: 0.1, height: 0.1)
            ))
        )
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.2))
        // The discharge tie sits on M2: it protects the M2 stage but does
        // not exist yet while M1 is being etched.
        let lateTie = LayoutPin(
            name: "source",
            position: LayoutPoint(x: 0.5, y: 0.2),
            size: LayoutSize(width: 0.1, height: 0.1),
            layer: m2,
            role: .source
        )

        let result = LayoutDRCService().run(
            document: document(shapes: [strap, m2Wire], vias: [via], pins: [gate, lateTie]),
            tech: antennaTech(rules: [
                LayoutAntennaRule(layerID: m1, maxRatio: 10),
                LayoutAntennaRule(layerID: m2, maxRatio: 10),
            ])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.M1.drawing.maxRatio")
    }

    // MARK: - Cumulative ratio (CAR)

    @Test func cumulativeRatioAccumulatesAcrossLayers() {
        let gate = gatePin()
        // M1 0.40 um^2 (PAR 40) and M2 0.20 um^2 (PAR 20) both pass their
        // per-layer limit of 1000, but the M2-stage cumulative 60 > 50.
        let m1Wire = m1Rect(x: -0.05, y: -0.05, width: 0.8, height: 0.5)
        let m2Wire = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.45, y: 0.15),
                size: LayoutSize(width: 0.5, height: 0.4)
            ))
        )
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.2))

        let result = LayoutDRCService().run(
            document: document(shapes: [m1Wire, m2Wire], vias: [via], pins: [gate]),
            tech: antennaTech(rules: [
                LayoutAntennaRule(layerID: m1, maxRatio: 1000),
                LayoutAntennaRule(layerID: m2, maxRatio: 1000, maxCumulativeRatio: 50),
            ])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        let violation = violations.first
        #expect(violation?.ruleID == "antenna.M2.drawing.maxCumulativeRatio")
        #expect(abs((violation?.measured ?? 0) - 60) < 1)
        #expect(violation?.required == 50)
    }

    // MARK: - Robustness

    @Test func componentsWithoutNetIDsAreStillChecked() {
        let gate = gatePin()
        let strap = m1Rect(x: -0.05, y: -0.05, width: 1.0, height: 0.5)

        let result = LayoutDRCService().run(
            document: document(shapes: [strap], pins: [gate]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.netIDs.isEmpty == true)
    }

    @Test func overlappingShapesAreaIsMergedNotDoubleCounted() {
        let gate = gatePin()
        // Two identical 0.08 um^2 rects: double-counting reads 16 > 10,
        // boolean merge reads 8 <= 10.
        let first = m1Rect(x: -0.05, y: -0.05, width: 0.4, height: 0.2)
        let second = m1Rect(x: -0.05, y: -0.05, width: 0.4, height: 0.2)

        let result = LayoutDRCService().run(
            document: document(shapes: [first, second], pins: [gate]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        #expect(!result.violations.contains { $0.kind == .antenna })
    }

    // MARK: - Configuration gaps are violations, never silent skips

    @Test func cyclicViaDefinitionsReportConfigurationViolation() {
        let via2 = LayoutLayerID(name: "VIA2", purpose: "cut")
        let tech = antennaTech(
            rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)],
            viaDefinitions: [
                viaDefinition(id: "VIA1", cut: via1, bottom: m1, top: m2),
                viaDefinition(id: "VIA2", cut: via2, bottom: m2, top: m1),
            ]
        )

        let result = LayoutDRCService().run(document: document(), tech: tech)

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.config.conductorStack")
    }

    @Test func ruleOnLayerOutsideStackReportsConfigurationViolation() {
        let m9 = LayoutLayerID(name: "M9", purpose: "drawing")

        let result = LayoutDRCService().run(
            document: document(),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m9, maxRatio: 10)])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.M9.drawing.maxRatio")
        #expect(violations.first?.message.contains("not part of the conductor stack") == true)
    }

    @Test func unknownViaDefinitionReportsConfigurationViolation() {
        let orphanVia = LayoutVia(viaDefinitionID: "MISSING", position: LayoutPoint(x: 0, y: 0))

        let result = LayoutDRCService().run(
            document: document(vias: [orphanVia]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.config.viaDefinition")
        #expect(violations.first?.message.contains("MISSING") == true)
    }

    @Test func gatePinOutsideStackReportsConfigurationViolation() {
        let poly = LayoutLayerID(name: "POLY", purpose: "drawing")
        let strandedGate = LayoutPin(
            name: "gate",
            position: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 0.1, height: 0.1),
            layer: poly,
            role: .gate
        )

        let result = LayoutDRCService().run(
            document: document(pins: [strandedGate]),
            tech: antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])
        )

        let violations = result.violations.filter { $0.kind == .antenna }
        #expect(violations.count == 1)
        #expect(violations.first?.ruleID == "antenna.config.gatePinLayer")
        #expect(violations.first?.pinIDs == [strandedGate.id])
    }

    // MARK: - Fixtures

    /// 0.1 x 0.1 gate pin (0.01 um^2) centered at the origin on M1.
    private func gatePin() -> LayoutPin {
        LayoutPin(
            name: "gate",
            position: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 0.1, height: 0.1),
            layer: m1,
            role: .gate
        )
    }

    private func m1Rect(
        x: Double, y: Double, width: Double, height: Double, netID: UUID? = nil
    ) -> LayoutShape {
        LayoutShape(
            layer: m1,
            netID: netID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: width, height: height)
            ))
        )
    }

    private func document(
        shapes: [LayoutShape] = [],
        vias: [LayoutVia] = [],
        pins: [LayoutPin] = []
    ) -> LayoutDocument {
        let cell = LayoutCell(
            name: "TOP", shapes: shapes, vias: vias, pins: pins, instances: [], nets: []
        )
        return LayoutDocument(name: "AntennaTest", cells: [cell], topCellID: cell.id)
    }

    private func antennaTech(
        rules: [LayoutAntennaRule],
        viaDefinitions: [LayoutViaDefinition]? = nil
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(m1), layerDefinition(m2), layerDefinition(via1)],
            vias: viaDefinitions ?? [viaDefinition(id: "VIA1", cut: via1, bottom: m1, top: m2)],
            layerRules: [relaxedRules(m1), relaxedRules(m2)],
            antennaRules: rules
        )
    }

    private func viaDefinition(
        id: String, cut: LayoutLayerID, bottom: LayoutLayerID, top: LayoutLayerID
    ) -> LayoutViaDefinition {
        LayoutViaDefinition(
            id: id,
            cutLayer: cut,
            topLayer: top,
            bottomLayer: bottom,
            cutSize: LayoutSize(width: 0.05, height: 0.05),
            enclosure: LayoutViaEnclosure(top: 0, bottom: 0),
            cutSpacing: 0.05
        )
    }

    private func relaxedRules(_ layer: LayoutLayerID) -> LayoutLayerRuleSet {
        LayoutLayerRuleSet(
            layerID: layer, minWidth: 0, minSpacing: 0,
            minArea: 0, minDensity: 0, maxDensity: 1
        )
    }

    private func layerDefinition(_ id: LayoutLayerID) -> LayoutLayerDefinition {
        LayoutLayerDefinition(
            id: id,
            displayName: id.name,
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
        )
    }
}
