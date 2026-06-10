import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Layout DRC Service Correctness")
struct LayoutDRCServiceCorrectnessTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    // MARK: - Net-blind spacing

    @Test func sameNetShapesTooCloseStillFlagSpacing() {
        let net = UUID()
        let first = rect(x: 0, y: 0, width: 1, height: 1, netID: net)
        let second = rect(x: 1.03, y: 0, width: 1, height: 1, netID: net)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minSpacing: 0.05)
        )

        let violation = result.violations.first { $0.kind == .minSpacing }
        #expect(violation != nil)
        #expect(violation?.measured ?? 1 < 0.05)
        #expect(violation?.shapeIDs == [first.id, second.id])
        #expect(violation?.netIDs == [net])
    }

    @Test func abuttingShapesDoNotFlagSpacing() {
        let first = rect(x: 0, y: 0, width: 1, height: 1)
        let second = rect(x: 1, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minSpacing: 0.05)
        )

        #expect(!result.violations.contains { $0.kind == .minSpacing })
    }

    @Test func overlappingShapesDoNotFlagSpacing() {
        let first = rect(x: 0, y: 0, width: 1, height: 1)
        let second = rect(x: 0.5, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minSpacing: 0.05)
        )

        #expect(!result.violations.contains { $0.kind == .minSpacing })
    }

    @Test func notchInsideSinglePolygonFlagsSpacing() {
        let u = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 0.3, y: 0),
                LayoutPoint(x: 0.3, y: 0.3),
                LayoutPoint(x: 0.2, y: 0.3),
                LayoutPoint(x: 0.2, y: 0.1),
                LayoutPoint(x: 0.1, y: 0.1),
                LayoutPoint(x: 0.1, y: 0.3),
                LayoutPoint(x: 0, y: 0.3),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [u]),
            tech: tech(minSpacing: 0.15)
        )

        let violation = result.violations.first { $0.kind == .minSpacing }
        #expect(violation != nil)
        #expect(abs((violation?.measured ?? 0) - 0.1) < 1.0e-9)
    }

    // MARK: - Notch rule

    @Test func notchRuleFlagsSameComponentGapAboveMinSpacing() {
        let u = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 0.3, y: 0),
                LayoutPoint(x: 0.3, y: 0.3),
                LayoutPoint(x: 0.2, y: 0.3),
                LayoutPoint(x: 0.2, y: 0.1),
                LayoutPoint(x: 0.1, y: 0.1),
                LayoutPoint(x: 0.1, y: 0.3),
                LayoutPoint(x: 0, y: 0.3),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [u]),
            tech: tech(minSpacing: 0.05, minNotch: 0.15)
        )

        // The 0.1 notch satisfies minSpacing but violates minNotch.
        #expect(!result.violations.contains { $0.kind == .minSpacing })
        let violation = result.violations.first { $0.kind == .notch }
        #expect(violation?.ruleID == "layer.M1.drawing.minNotch")
        #expect(abs((violation?.measured ?? 0) - 0.1) < 1.0e-9)
    }

    @Test func notchRuleIgnoresGapsBetweenSeparateFeatures() {
        let first = rect(x: 0, y: 0, width: 1, height: 1)
        let second = rect(x: 1.1, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minSpacing: 0.05, minNotch: 0.15)
        )

        #expect(!result.violations.contains { $0.kind == .notch })
    }

    // MARK: - Wide-metal spacing

    @Test func wideMetalRequiresExtraSpacing() {
        let wide = rect(x: 0, y: 0, width: 2, height: 2)
        let narrow = rect(x: 2.2, y: 0, width: 0.1, height: 2)
        let result = LayoutDRCService().run(
            document: document(shapes: [wide, narrow]),
            tech: tech(minSpacing: 0.05, wideWidthThreshold: 1.0, wideSpacing: 0.5)
        )

        let violation = result.violations.first { $0.ruleID == "layer.M1.drawing.wideSpacing" }
        #expect(violation != nil)
        #expect(abs((violation?.measured ?? 0) - 0.2) < 1.0e-9)
    }

    @Test func narrowMetalDoesNotTriggerWideSpacing() {
        let first = rect(x: 0, y: 0, width: 0.1, height: 2)
        let second = rect(x: 0.3, y: 0, width: 0.1, height: 2)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minSpacing: 0.05, wideWidthThreshold: 1.0, wideSpacing: 0.5)
        )

        #expect(!result.violations.contains { $0.ruleID == "layer.M1.drawing.wideSpacing" })
    }

    // MARK: - Merged width and area

    @Test func abuttingNarrowStripsMeetMinWidthTogether() {
        let first = rect(x: 0, y: 0, width: 0.3, height: 1)
        let second = rect(x: 0.3, y: 0, width: 0.3, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minWidth: 0.5)
        )

        #expect(!result.violations.contains { $0.kind == .minWidth })
    }

    @Test func isolatedNarrowStripFlagsMinWidth() {
        let strip = rect(x: 0, y: 0, width: 0.3, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [strip]),
            tech: tech(minWidth: 0.5)
        )

        let violation = result.violations.first { $0.kind == .minWidth }
        #expect(violation?.shapeIDs == [strip.id])
        #expect(abs((violation?.measured ?? 0) - 0.3) < 1.0e-9)
    }

    @Test func abuttingSmallShapesMeetMinAreaTogether() {
        let first = rect(x: 0, y: 0, width: 0.5, height: 1)
        let second = rect(x: 0.5, y: 0, width: 0.5, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minArea: 1.0)
        )

        #expect(!result.violations.contains { $0.kind == .minArea })
    }

    @Test func minEnclosedAreaFlagsSmallHole() {
        // Four rects forming a ring around a 0.2 x 0.2 hole.
        let shapes = [
            rect(x: 0, y: 0, width: 0.4, height: 1),
            rect(x: 0.6, y: 0, width: 0.4, height: 1),
            rect(x: 0.4, y: 0, width: 0.2, height: 0.4),
            rect(x: 0.4, y: 0.6, width: 0.2, height: 0.4),
        ]
        let result = LayoutDRCService().run(
            document: document(shapes: shapes),
            tech: tech(minEnclosedArea: 0.1)
        )

        let violation = result.violations.first { $0.kind == .minEnclosedArea }
        #expect(violation?.ruleID == "layer.M1.drawing.minEnclosedArea")
        #expect(abs((violation?.measured ?? 0) - 0.04) < 1.0e-9)
    }

    @Test func solidGeometryHasNoEnclosedAreaViolation() {
        let solid = rect(x: 0, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [solid]),
            tech: tech(minEnclosedArea: 0.1)
        )

        #expect(!result.violations.contains { $0.kind == .minEnclosedArea })
    }

    // MARK: - Via enclosure by merged coverage

    @Test func viaEnclosedByTwoAbuttingShapesPasses() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let bottom = rect(x: 0, y: 0, width: 2, height: 2)
        let topLeft = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 1, height: 2)
            ))
        )
        let topRight = LayoutShape(
            layer: m2,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 1, y: 0),
                size: LayoutSize(width: 1, height: 2)
            ))
        )
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 1))
        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, topLeft, topRight], vias: [via]),
            tech: viaTech(m1: m1, m2: m2, cut: cut)
        )

        #expect(!result.violations.contains { $0.kind == .enclosure })
    }

    // MARK: - Union-coverage width

    @Test func staircaseOverlapBetweenWiresDoesNotFlagWidth() {
        // Two same-width wires overlapping with a 0.01µm vertical offset:
        // the seam between them is not a width feature of the merged metal.
        let first = rect(x: 0.02, y: 3.07, width: 0.43, height: 0.28)
        let second = rect(x: 0.40, y: 3.08, width: 7.36, height: 0.28)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(minWidth: 0.28)
        )

        #expect(!result.violations.contains { $0.kind == .minWidth })
    }

    // MARK: - Layer-pair enclosure

    private let polyLayer = LayoutLayerID(name: "POLY", purpose: "drawing")
    private let resiLayer = LayoutLayerID(name: "RESI", purpose: "drawing")

    @Test func passThroughEnclosureAllowsResistorTerminals() {
        // Resistor poly crosses the RESI marker to reach its terminals;
        // side margins are 0.1µm so the covered body satisfies the rule.
        let body = shape(layer: polyLayer, x: 0, y: 1.0, width: 3, height: 0.4)
        let marker = shape(layer: resiLayer, x: 0.5, y: 0.9, width: 2, height: 0.6)
        let result = LayoutDRCService().run(
            document: document(shapes: [body, marker]),
            tech: enclosureTech(outer: resiLayer, inner: polyLayer, minEnclosure: 0.1, allowsPassThrough: true)
        )

        #expect(!result.violations.contains { $0.kind == .enclosure })
    }

    @Test func passThroughEnclosureFlagsInsufficientSideMargin() {
        // Marker keeps only 0.05µm above and below the poly body.
        let body = shape(layer: polyLayer, x: 0, y: 1.0, width: 3, height: 0.4)
        let marker = shape(layer: resiLayer, x: 0.5, y: 0.95, width: 2, height: 0.5)
        let result = LayoutDRCService().run(
            document: document(shapes: [body, marker]),
            tech: enclosureTech(outer: resiLayer, inner: polyLayer, minEnclosure: 0.1, allowsPassThrough: true)
        )

        let violations = result.violations.filter { $0.kind == .enclosure }
        #expect(violations.count == 2)
        for violation in violations {
            #expect(abs((violation.measured ?? 0) - 0.05) < 1.0e-9)
        }
    }

    @Test func enclosureRuleIgnoresNonInteractingInner() {
        // NMOS-style: inner geometry that never touches the outer layer is
        // outside the rule's scope.
        let inner = shape(layer: polyLayer, x: 5, y: 5, width: 1, height: 1)
        let outer = shape(layer: resiLayer, x: 0, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [inner, outer]),
            tech: enclosureTech(outer: resiLayer, inner: polyLayer, minEnclosure: 0.1)
        )

        #expect(!result.violations.contains { $0.kind == .enclosure })
    }

    @Test func partialCoverageFlagsProtrusionWithoutPassThrough() {
        // Without pass-through, an interacting inner feature must be fully
        // contained: the uncovered half is one protrusion violation.
        let inner = shape(layer: polyLayer, x: 0, y: 0, width: 2, height: 0.4)
        let outer = shape(layer: resiLayer, x: 1, y: -1, width: 3, height: 2.4)
        let result = LayoutDRCService().run(
            document: document(shapes: [inner, outer]),
            tech: enclosureTech(outer: resiLayer, inner: polyLayer, minEnclosure: 0.1)
        )

        let violations = result.violations.filter { $0.kind == .enclosure }
        #expect(violations.count == 1)
        #expect(violations.first?.measured == 0)
        #expect(violations.first?.message.contains("extends outside") == true)
    }

    @Test func fullyContainedInnerStillRequiresMargin() {
        // Contained on all sides but with only 0.05µm margin against a
        // 0.1µm rule: one ring-shaped deficit, measured at 0.05µm.
        let inner = shape(layer: polyLayer, x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let outer = shape(layer: resiLayer, x: 0, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [inner, outer]),
            tech: enclosureTech(outer: resiLayer, inner: polyLayer, minEnclosure: 0.1)
        )

        let violations = result.violations.filter { $0.kind == .enclosure }
        #expect(violations.count == 1)
        #expect(abs((violations.first?.measured ?? 0) - 0.05) < 1.0e-9)
    }

    // MARK: - Helpers

    private func document(shapes: [LayoutShape], vias: [LayoutVia] = []) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes, vias: vias)
        return LayoutDocument(name: "drc-correctness", cells: [cell], topCellID: cell.id)
    }

    private func rect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        netID: UUID? = nil
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

    private func tech(
        minWidth: Double = 0,
        minSpacing: Double = 0,
        minArea: Double = 0,
        minNotch: Double? = nil,
        wideWidthThreshold: Double? = nil,
        wideSpacing: Double? = nil,
        minEnclosedArea: Double? = nil
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: m1)],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: minWidth,
                    minSpacing: minSpacing,
                    minArea: minArea,
                    minDensity: 0,
                    maxDensity: 1,
                    minNotch: minNotch,
                    wideWidthThreshold: wideWidthThreshold,
                    wideSpacing: wideSpacing,
                    minEnclosedArea: minEnclosedArea
                )
            ]
        )
    }

    private func shape(
        layer: LayoutLayerID,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> LayoutShape {
        LayoutShape(
            layer: layer,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: width, height: height)
            ))
        )
    }

    private func enclosureTech(
        outer: LayoutLayerID,
        inner: LayoutLayerID,
        minEnclosure: Double,
        allowsPassThrough: Bool = false
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: outer), layerDefinition(id: inner)],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: outer,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
                LayoutLayerRuleSet(
                    layerID: inner,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ],
            enclosureRules: [
                LayoutEnclosureRule(
                    outerLayer: outer,
                    innerLayer: inner,
                    minEnclosure: minEnclosure,
                    allowsPassThrough: allowsPassThrough
                )
            ]
        )
    }

    private func viaTech(
        m1: LayoutLayerID,
        m2: LayoutLayerID,
        cut: LayoutLayerID
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: m1), layerDefinition(id: m2), layerDefinition(id: cut)],
            vias: [
                LayoutViaDefinition(
                    id: "VIA1",
                    cutLayer: cut,
                    topLayer: m2,
                    bottomLayer: m1,
                    cutSize: LayoutSize(width: 0.2, height: 0.2),
                    enclosure: LayoutViaEnclosure(top: 0.1, bottom: 0.1),
                    cutSpacing: 0.1
                )
            ],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
                LayoutLayerRuleSet(
                    layerID: m2,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ]
        )
    }

    private func layerDefinition(id: LayoutLayerID) -> LayoutLayerDefinition {
        LayoutLayerDefinition(
            id: id,
            displayName: id.name,
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
        )
    }
}
