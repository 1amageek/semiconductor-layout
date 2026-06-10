import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutAutoGen
import LayoutVerify

/// The inserter performs local rectangle surgery; these tests use a DRC
/// rerun as the oracle for whether the mitigation actually cleared the
/// antenna violation.
@Suite("Antenna Jumper Inserter")
struct AntennaJumperInserterTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
    private let via1 = LayoutLayerID(name: "VIA1", purpose: "cut")

    @Test func jumperSplitsTheWireNearTheGate() throws {
        let gate = gatePin()
        // 2.0 x 0.1 = 0.2 um^2 against a 0.01 um^2 gate: ratio 20 > 10.
        let wire = m1Rect(x: -0.05, y: -0.05, width: 2.0, height: 0.1)
        var doc = document(shapes: [wire], pins: [gate])
        let tech = antennaTech(rules: [
            LayoutAntennaRule(layerID: m1, maxRatio: 10),
            LayoutAntennaRule(layerID: m2, maxRatio: 10),
        ])

        let before = LayoutDRCService().run(document: doc, tech: tech)
        let violation = try #require(
            before.violations.first { $0.kind == .antenna }
        )

        let result = try AntennaJumperInserter().insert(
            requests: [AntennaJumperRequest(
                layer: m1,
                shapeIDs: violation.shapeIDs,
                gates: [AntennaJumperGate(position: gate.position, size: gate.size)]
            )],
            into: &doc,
            cellID: try #require(doc.topCellID),
            tech: tech
        )

        #expect(result.insertedJumpers == 1)
        #expect(result.failures.isEmpty)

        let after = LayoutDRCService().run(document: doc, tech: tech)
        #expect(!after.violations.contains { $0.kind == .antenna })
    }

    @Test func topLayerViolationReportsNoBridgeLayer() throws {
        // No via definition has M2 as its bottom layer, so an M2 antenna
        // violation cannot be jumpered; it needs a diode or diffusion tie.
        let plate = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.05, y: -0.05),
                size: LayoutSize(width: 2.0, height: 0.1)
            ))
        )
        var doc = document(shapes: [plate])
        let tech = antennaTech(rules: [LayoutAntennaRule(layerID: m2, maxRatio: 10)])

        let result = try AntennaJumperInserter().insert(
            requests: [AntennaJumperRequest(
                layer: m2,
                shapeIDs: [plate.id],
                gates: [AntennaJumperGate(
                    position: LayoutPoint(x: 0, y: 0),
                    size: LayoutSize(width: 0.1, height: 0.1)
                )]
            )],
            into: &doc,
            cellID: try #require(doc.topCellID),
            tech: tech
        )

        #expect(result.insertedJumpers == 0)
        #expect(result.failures.map(\.reason) == [.noBridgeLayerAbove(m2)])
    }

    @Test func wireTooShortReportsFailure() throws {
        // bottomLanding 0.07 + gap 0.01 + bottomLanding 0.07 = 0.15 exceeds
        // the 0.1 wire length, so there is no room for the split.
        let gate = gatePin()
        let wire = m1Rect(x: -0.05, y: -0.05, width: 0.1, height: 0.1)
        var doc = document(shapes: [wire], pins: [gate])
        let tech = antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])

        let result = try AntennaJumperInserter().insert(
            requests: [AntennaJumperRequest(
                layer: m1,
                shapeIDs: [wire.id],
                gates: [AntennaJumperGate(position: gate.position, size: gate.size)]
            )],
            into: &doc,
            cellID: try #require(doc.topCellID),
            tech: tech
        )

        #expect(result.insertedJumpers == 0)
        #expect(result.failures.map(\.reason) == [.noSplittableWireNearGate])
        // The failed pass must not leave partial edits behind.
        let topCellID = try #require(doc.topCellID)
        let cell = try #require(doc.cell(withID: topCellID))
        #expect(cell.shapes.count == 1)
        #expect(cell.vias.isEmpty)
    }

    @Test func netIDIsPreservedOnAllJumperGeometry() throws {
        let net = UUID()
        let gate = gatePin()
        let wire = m1Rect(x: -0.05, y: -0.05, width: 2.0, height: 0.1, netID: net)
        var doc = document(shapes: [wire], pins: [gate])
        let tech = antennaTech(rules: [LayoutAntennaRule(layerID: m1, maxRatio: 10)])

        let result = try AntennaJumperInserter().insert(
            requests: [AntennaJumperRequest(
                layer: m1,
                shapeIDs: [wire.id],
                gates: [AntennaJumperGate(position: gate.position, size: gate.size)]
            )],
            into: &doc,
            cellID: try #require(doc.topCellID),
            tech: tech
        )

        #expect(result.insertedJumpers == 1)
        let topCellID = try #require(doc.topCellID)
        let cell = try #require(doc.cell(withID: topCellID))
        // Stub + far piece + two landing pads + bridge.
        #expect(cell.shapes.count == 5)
        #expect(cell.shapes.allSatisfy { $0.netID == net })
        #expect(cell.vias.count == 2)
        #expect(cell.vias.allSatisfy { $0.netID == net })
        // The stub keeps the original shape ID so follow-up requests built
        // from the same violation still resolve.
        #expect(cell.shapes.contains { $0.id == wire.id })
        // Exactly one shape moved to the bridge layer.
        #expect(cell.shapes.filter { $0.layer == m2 }.count == 1)
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
        return LayoutDocument(name: "JumperTest", cells: [cell], topCellID: cell.id)
    }

    private func antennaTech(rules: [LayoutAntennaRule]) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(m1), layerDefinition(m2), layerDefinition(via1)],
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: via1,
                    topLayer: m2,
                    bottomLayer: m1,
                    cutSize: LayoutSize(width: 0.05, height: 0.05),
                    enclosure: LayoutViaEnclosure(top: 0.01, bottom: 0.01),
                    cutSpacing: 0.05
                )
            ],
            layerRules: [relaxedRules(m1), relaxedRules(m2)],
            antennaRules: rules
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
