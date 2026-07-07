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

    @Test func forbiddenLayerRuleFlagsMarkerGeometryWithoutRuleCoverageNoise() {
        let marker = LayoutLayerID(name: "NWELL_MISSING", purpose: "marker")
        let shape = shape(layer: marker, x: 0, y: 0, width: 1, height: 1)

        let result = LayoutDRCService().run(
            document: document(shapes: [shape]),
            tech: forbiddenLayerTech(marker)
        )

        let violation = result.violations.first { $0.kind == .forbiddenLayer }
        #expect(violation?.ruleID == "forbiddenLayer.NWELL_MISSING.marker.forbiddenLayer.NWELL_MISSING")
        #expect(violation?.shapeIDs == [shape.id])
        #expect(violation?.measured == 1)
        #expect(violation?.required == 0)
        #expect(!result.violations.contains { $0.kind == .ruleCoverage })
    }

    @Test func derivedForbiddenLayerRuleRunsThroughDirectDRCService() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let marker = LayoutLayerID(name: "M1_NOT_M2", purpose: "marker")
        let first = shape(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let second = shape(layer: m2, x: 0.5, y: 0, width: 0.5, height: 1)

        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: derivedDifferenceForbiddenLayerTech(
                secondary: m2,
                marker: marker
            )
        )

        let violation = result.violations.first { $0.kind == .forbiddenLayer }
        #expect(violation?.ruleID == "forbiddenLayer.M1_NOT_M2.marker.forbiddenLayer.M1_NOT_M2")
        #expect(violation?.layer == marker)
        #expect(violation?.measured == 1)
        #expect(violation?.required == 0)
        #expect(abs((violation?.region.origin.x ?? 0) - 0) < 1.0e-9)
        #expect(abs((violation?.region.size.width ?? 0) - 0.5) < 1.0e-9)
        #expect(!result.violations.contains { $0.kind == .ruleCoverage })
    }

    @Test func derivedLayerMaterializationIsIdempotent() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let marker = LayoutLayerID(name: "M1_NOT_M2", purpose: "marker")
        let first = shape(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let second = shape(layer: m2, x: 0.5, y: 0, width: 0.5, height: 1)
        let tech = derivedDifferenceForbiddenLayerTech(secondary: m2, marker: marker)
        let once = LayoutDerivedLayerMaterializer.materialize(
            document: document(shapes: [first, second]),
            tech: tech
        )
        let twice = LayoutDerivedLayerMaterializer.materialize(document: once, tech: tech)

        #expect(once.cells[0].shapes.filter { $0.layer == marker }.count == 1)
        #expect(twice.cells[0].shapes.filter { $0.layer == marker }.count == 1)
    }

    @Test func incrementalDRCRebuildsDerivedLayerAfterBaseShapeUpdate() throws {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let marker = LayoutLayerID(name: "M1_NOT_M2", purpose: "marker")
        let first = shape(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let second = shape(layer: m2, x: 0.5, y: 0, width: 0.5, height: 1)
        let tech = derivedDifferenceForbiddenLayerTech(secondary: m2, marker: marker)
        let session = try IncrementalDRCSession(
            document: document(shapes: [first, second]),
            tech: tech
        )

        #expect(session.currentResult.violations.contains { $0.kind == .forbiddenLayer })

        var covering = second
        covering.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 1, height: 1)
        ))
        let update = try session.apply(LayoutEditDelta(updatedShapes: [covering]))

        #expect(!update.result.violations.contains { $0.kind == .forbiddenLayer })
        #expect(update.staleKinds.isEmpty)
        #expect(update.recomputedLayers.contains(marker))
    }

    @Test func incrementalDRCRecomputesForbiddenLayerAfterShapeUpdate() throws {
        let marker = LayoutLayerID(name: "NWELL_MISSING", purpose: "marker")
        let shape = shape(layer: marker, x: 0, y: 0, width: 1, height: 1)
        let document = document(shapes: [shape])
        let session = try IncrementalDRCSession(
            document: document,
            tech: forbiddenLayerTech(marker)
        )

        #expect(session.currentResult.violations.contains { $0.kind == .forbiddenLayer })

        var updated = document
        updated.cells[0].shapes = []
        let update = try session.rebuild(document: updated)

        #expect(!update.violations.contains { $0.kind == .forbiddenLayer })
    }

    @Test func layerPairSpacingFlagsCrossLayerClearance() {
        let active = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let nwell = LayoutLayerID(name: "NWELL", purpose: "drawing")
        let first = shape(layer: active, x: 0, y: 0, width: 1, height: 1)
        let second = shape(layer: nwell, x: 1.03, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: pairSpacingTech(
                primary: active,
                secondary: nwell,
                minSpacing: 0.05
            )
        )

        let violation = result.violations.first { $0.ruleID == "spacing.ACTIVE.drawing.NWELL.drawing.active.nwell.spacing" }
        #expect(violation?.kind == .minSpacing)
        #expect(abs((violation?.measured ?? 0) - 0.03) < 1.0e-9)
        #expect(violation?.required == 0.05)
        #expect(violation?.shapeIDs == [first.id, second.id])
    }

    @Test func incrementalDRCRecomputesLayerPairSpacingAfterShapeUpdate() throws {
        let active = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let nwell = LayoutLayerID(name: "NWELL", purpose: "drawing")
        let first = shape(layer: active, x: 0, y: 0, width: 1, height: 1)
        let second = shape(layer: nwell, x: 1.03, y: 0, width: 1, height: 1)
        var moved = second
        moved.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 1.1, y: 0),
            size: LayoutSize(width: 1, height: 1)
        ))
        let session = try IncrementalDRCSession(
            document: document(shapes: [first, second]),
            tech: pairSpacingTech(
                primary: active,
                secondary: nwell,
                minSpacing: 0.05
            )
        )

        #expect(session.currentResult.violations.contains { $0.ruleID == "spacing.ACTIVE.drawing.NWELL.drawing.active.nwell.spacing" })
        let update = try session.apply(LayoutEditDelta(updatedShapes: [moved]))

        #expect(!update.result.violations.contains { $0.ruleID == "spacing.ACTIVE.drawing.NWELL.drawing.active.nwell.spacing" })
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

    // MARK: - Rect-only rule

    @Test func rectOnlyRuleFlagsNonRectangularPolygon() {
        let lShape = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 2, y: 0),
                LayoutPoint(x: 2, y: 1),
                LayoutPoint(x: 1, y: 1),
                LayoutPoint(x: 1, y: 2),
                LayoutPoint(x: 0, y: 2),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [lShape]),
            tech: tech(requiresRectangular: true)
        )

        let violation = result.violations.first { $0.kind == .rectOnly }
        #expect(violation?.ruleID == "layer.M1.drawing.rectOnly")
        #expect(violation?.shapeIDs == [lShape.id])
    }

    @Test func rectOnlyRuleAcceptsRectanglePolygon() {
        let rectanglePolygon = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 2, y: 0),
                LayoutPoint(x: 2, y: 1),
                LayoutPoint(x: 0, y: 1),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [rectanglePolygon]),
            tech: tech(requiresRectangular: true)
        )

        #expect(!result.violations.contains { $0.kind == .rectOnly })
    }

    @Test func incrementalDRCRecomputesRectOnlyAfterShapeUpdate() throws {
        let original = rect(x: 0, y: 0, width: 2, height: 2)
        var edited = original
        edited.geometry = .polygon(LayoutPolygon(points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 2, y: 0),
            LayoutPoint(x: 2, y: 1),
            LayoutPoint(x: 1, y: 1),
            LayoutPoint(x: 1, y: 2),
            LayoutPoint(x: 0, y: 2),
        ]))
        let session = try IncrementalDRCSession(
            document: document(shapes: [original]),
            tech: tech(requiresRectangular: true)
        )

        let update = try session.apply(LayoutEditDelta(updatedShapes: [edited]))

        #expect(update.result.violations.contains { $0.kind == .rectOnly && $0.shapeIDs == [original.id] })
    }

    // MARK: - Angle rule

    @Test func angleRuleFlagsNonManhattanEdgeWhenStepIs90Degrees() {
        let angled = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 1, y: 0),
                LayoutPoint(x: 2, y: 1),
                LayoutPoint(x: 0, y: 1),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [angled]),
            tech: tech(allowedAngleStepDegrees: 90)
        )

        let violation = result.violations.first { $0.kind == .angle }
        #expect(violation?.ruleID == "layer.M1.drawing.angle")
        #expect(violation?.shapeIDs == [angled.id])
        #expect(violation?.measured == 45)
        #expect(violation?.required == 90)
    }

    @Test func angleRuleAcceptsFortyFiveDegreeEdgeWhenStepIs45Degrees() {
        let angled = LayoutShape(
            layer: m1,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 1, y: 0),
                LayoutPoint(x: 2, y: 1),
                LayoutPoint(x: 0, y: 1),
            ]))
        )
        let result = LayoutDRCService().run(
            document: document(shapes: [angled]),
            tech: tech(allowedAngleStepDegrees: 45)
        )

        #expect(!result.violations.contains { $0.kind == .angle })
    }

    @Test func incrementalDRCRecomputesAngleAfterShapeUpdate() throws {
        let original = rect(x: 0, y: 0, width: 2, height: 1)
        var edited = original
        edited.geometry = .polygon(LayoutPolygon(points: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 1, y: 0),
            LayoutPoint(x: 2, y: 1),
            LayoutPoint(x: 0, y: 1),
        ]))
        let session = try IncrementalDRCSession(
            document: document(shapes: [original]),
            tech: tech(allowedAngleStepDegrees: 90)
        )

        let update = try session.apply(LayoutEditDelta(updatedShapes: [edited]))

        #expect(update.result.violations.contains { $0.kind == .angle && $0.shapeIDs == [original.id] })
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

    @Test func viaEnclosureUsesExplicitViaLayerGeometry() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 1))

        let result = LayoutDRCService().run(
            document: document(shapes: [], vias: [via]),
            tech: explicitMultiCutViaTech(m2: m2, cut: cut, enclosure: 0.05)
        )

        #expect(!result.violations.contains { $0.kind == .enclosure })
    }

    @Test func viaEnclosureChecksEveryExplicitCutRect() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        var tech = explicitMultiCutViaTech(m2: m2, cut: cut, enclosure: 0.05)
        tech.vias[0].layerGeometries = [
            LayoutViaLayerGeometry(layer: cut, rects: multiCutRects()),
            LayoutViaLayerGeometry(
                layer: m1,
                rects: [LayoutRect(
                    origin: LayoutPoint(x: -0.4, y: -0.15),
                    size: LayoutSize(width: 0.35, height: 0.3)
                )]
            ),
            LayoutViaLayerGeometry(
                layer: m2,
                rects: [LayoutRect(
                    origin: LayoutPoint(x: -0.4, y: -0.15),
                    size: LayoutSize(width: 0.35, height: 0.3)
                )]
            ),
        ]
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 1))

        let result = LayoutDRCService().run(
            document: document(shapes: [], vias: [via]),
            tech: tech
        )

        let violations = result.violations.filter { $0.kind == .enclosure }
        #expect(!violations.isEmpty)
        #expect(violations.contains { $0.region.minX > 1 })
    }

    // MARK: - Minimum cut-count rules

    @Test func minimumCutRuleFlagsSameNetOverlapWithoutCut() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let net = UUID()
        let bottom = rect(x: 0, y: 0, width: 1, height: 1, netID: net)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1, netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 1)
        )

        let violation = result.violations.first { $0.kind == .minimumCut }
        #expect(violation?.ruleID == "minimumCut.VIA1.cut.M1.drawing.M2.drawing.mincut.VIA1")
        #expect(violation?.measured == 0)
        #expect(violation?.required == 1)
        #expect(violation?.unit == "cut")
        #expect(violation?.shapeIDs == [bottom.id, top.id])
        #expect(violation?.netIDs == [net])
    }

    @Test func minimumCutRuleAcceptsMatchingVia() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let net = UUID()
        let bottom = rect(x: 0, y: 0, width: 1, height: 1, netID: net)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1, netID: net)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.5), netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top], vias: [via]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 1)
        )

        #expect(!result.violations.contains { $0.kind == .minimumCut })
    }

    @Test func minimumCutRuleCountsExplicitViaCutGeometry() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let net = UUID()
        let bottom = rect(x: 0, y: 0, width: 2, height: 1, netID: net)
        let top = shape(layer: m2, x: 0, y: 0, width: 2, height: 1, netID: net)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 0.5), netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top], vias: [via]),
            tech: explicitMultiCutMinimumCutTech(m2: m2, cut: cut, minimumCount: 2)
        )

        #expect(!result.violations.contains { $0.kind == .minimumCut })
    }

    @Test func minimumCutRuleFlagsInsufficientMultiCutCount() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let net = UUID()
        let bottom = rect(x: 0, y: 0, width: 1, height: 1, netID: net)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1, netID: net)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.5), netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top], vias: [via]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 2)
        )

        let violation = result.violations.first { $0.kind == .minimumCut }
        #expect(violation?.measured == 1)
        #expect(violation?.required == 2)
        #expect(violation?.viaIDs == [via.id])
    }

    @Test func minimumCutRuleCountsExplicitCutShape() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let net = UUID()
        let bottom = rect(x: 0, y: 0, width: 1, height: 1, netID: net)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1, netID: net)
        let cutShape = shape(layer: cut, x: 0.45, y: 0.45, width: 0.1, height: 0.1, netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top, cutShape]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 1)
        )

        #expect(!result.violations.contains { $0.kind == .minimumCut })
    }

    @Test func minimumCutRuleFlagsNetlessStandardMaskConnectionWithInsufficientCutShapes() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let bottom = rect(x: 0, y: 0, width: 1, height: 1)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1)
        let cutShape = shape(layer: cut, x: 0.45, y: 0.45, width: 0.1, height: 0.1)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top, cutShape]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 2)
        )

        let violation = result.violations.first { $0.kind == .minimumCut }
        #expect(violation?.measured == 1)
        #expect(violation?.required == 2)
        #expect(violation?.shapeIDs == [bottom.id, top.id, cutShape.id])
        #expect(violation?.netIDs.isEmpty == true)
    }

    @Test func minimumCutRuleIgnoresNetlessStandardMaskCrossingWithoutCuts() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let bottom = rect(x: 0, y: 0, width: 1, height: 1)
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1)

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 1)
        )

        #expect(!result.violations.contains { $0.kind == .minimumCut })
    }

    @Test func minimumCutRuleIgnoresDifferentNetOverlap() {
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let bottom = rect(x: 0, y: 0, width: 1, height: 1, netID: UUID())
        let top = shape(layer: m2, x: 0, y: 0, width: 1, height: 1, netID: UUID())

        let result = LayoutDRCService().run(
            document: document(shapes: [bottom, top]),
            tech: minimumCutTech(m2: m2, cut: cut, minimumCount: 1)
        )

        #expect(!result.violations.contains { $0.kind == .minimumCut })
    }

    // MARK: - Exact-overlap rules

    @Test func exactOverlapRuleFlagsMismatchedSecondaryBounds() {
        let marker = LayoutLayerID(name: "M1MARK", purpose: "drawing")
        let net = UUID()
        let primary = shape(layer: m1, x: 0, y: 0, width: 1, height: 1, netID: net)
        let secondary = shape(layer: marker, x: 0, y: 0, width: 1.1, height: 1, netID: net)

        let result = LayoutDRCService().run(
            document: document(shapes: [primary, secondary]),
            tech: exactOverlapTech(primary: m1, secondary: marker)
        )

        let violation = result.violations.first { $0.kind == .exactOverlap }
        #expect(violation?.ruleID == "exactOverlap.M1.drawing.M1MARK.drawing.exactOverlap.M1.M1MARK")
        #expect(violation?.shapeIDs == [primary.id, secondary.id])
        #expect(violation?.netIDs == [net])
        #expect(abs((violation?.measured ?? 0) - 0.1) < 1.0e-9)
        #expect(violation?.required == 0)
        #expect(violation?.region == LayoutGeometryAnalysis.boundingBox(for: primary.geometry))
    }

    @Test func exactOverlapRuleAcceptsMatchingSecondaryBounds() {
        let marker = LayoutLayerID(name: "M1MARK", purpose: "drawing")
        let primary = shape(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let secondary = shape(layer: marker, x: 0, y: 0, width: 1, height: 1)

        let result = LayoutDRCService().run(
            document: document(shapes: [primary, secondary]),
            tech: exactOverlapTech(primary: m1, secondary: marker)
        )

        #expect(!result.violations.contains { $0.kind == .exactOverlap })
    }

    @Test func exactOverlapRuleAcceptsAnyMatchingSecondaryLayer() {
        let contact = LayoutLayerID(name: "CONT", purpose: "cut")
        let diff = LayoutLayerID(name: "DIFF", purpose: "drawing")
        let poly = LayoutLayerID(name: "POLY", purpose: "drawing")
        let primary = shape(layer: contact, x: 0, y: 0, width: 1, height: 1)
        let matchingPoly = shape(layer: poly, x: 0, y: 0, width: 1, height: 1)

        let result = LayoutDRCService().run(
            document: document(shapes: [primary, matchingPoly]),
            tech: exactOverlapTech(primary: contact, secondaryLayers: [diff, poly])
        )

        #expect(!result.violations.contains { $0.kind == .exactOverlap })
    }

    @Test func exactOverlapRuleDecodesLegacySingleSecondaryArtifact() throws {
        let json = """
        {
          "id": "exactOverlap.CONT.DIFF",
          "primaryLayer": { "name": "CONT", "purpose": "cut" },
          "secondaryLayer": { "name": "DIFF", "purpose": "drawing" },
          "tolerance": 0
        }
        """

        let rule = try JSONDecoder().decode(
            LayoutExactOverlapRule.self,
            from: Data(json.utf8)
        )

        #expect(rule.id == "exactOverlap.CONT.DIFF")
        #expect(rule.primaryLayer == LayoutLayerID(name: "CONT", purpose: "cut"))
        #expect(rule.secondaryLayer == LayoutLayerID(name: "DIFF", purpose: "drawing"))
        #expect(rule.secondaryLayers == [LayoutLayerID(name: "DIFF", purpose: "drawing")])
    }

    @Test func exactOverlapRuleEncodesOneOfSecondaryArtifact() throws {
        let diff = LayoutLayerID(name: "DIFF", purpose: "drawing")
        let poly = LayoutLayerID(name: "POLY", purpose: "drawing")
        let rule = LayoutExactOverlapRule(
            id: "exactOverlap.CONT.oneOf.DIFF.POLY",
            primaryLayer: LayoutLayerID(name: "CONT", purpose: "cut"),
            secondaryLayers: [diff, poly]
        )

        let data = try JSONEncoder().encode(rule)
        let text = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(LayoutExactOverlapRule.self, from: data)

        #expect(text.contains("\"secondaryLayer\""))
        #expect(text.contains("\"secondaryLayers\""))
        #expect(decoded.secondaryLayer == diff)
        #expect(decoded.secondaryLayers == [diff, poly])
    }

    @Test func exactOverlapRuleRejectsEmptySecondaryLayers() {
        #expect(throws: LayoutExactOverlapRuleError.emptySecondaryLayers(ruleID: "exactOverlap.invalid")) {
            _ = try LayoutExactOverlapRule(
                validatingID: "exactOverlap.invalid",
                primaryLayer: LayoutLayerID(name: "CONT", purpose: "cut"),
                secondaryLayers: []
            )
        }
    }

    @Test func incrementalDRCRecomputesExactOverlapAfterShapeUpdate() throws {
        let marker = LayoutLayerID(name: "M1MARK", purpose: "drawing")
        let primary = shape(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let secondary = shape(layer: marker, x: 0, y: 0, width: 1.1, height: 1)
        let session = try IncrementalDRCSession(
            document: document(shapes: [primary, secondary]),
            tech: exactOverlapTech(primary: m1, secondary: marker)
        )

        #expect(session.currentResult.violations.contains { $0.kind == .exactOverlap })

        var edited = secondary
        edited.geometry = .rect(LayoutRect(
            origin: LayoutPoint(x: 0, y: 0),
            size: LayoutSize(width: 1, height: 1)
        ))
        let update = try session.apply(LayoutEditDelta(updatedShapes: [edited]))

        #expect(!update.result.violations.contains { $0.kind == .exactOverlap })
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

    // MARK: - Layer-pair extension

    @Test func extensionRuleFlagsInsufficientHorizontalOverhang() {
        let activeLayer = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let poly = shape(layer: polyLayer, x: -0.05, y: 0.0, width: 1.1, height: 0.1)
        let active = shape(layer: activeLayer, x: 0.0, y: -0.2, width: 1.0, height: 0.5)
        let result = LayoutDRCService().run(
            document: document(shapes: [poly, active]),
            tech: extensionTech(
                extending: polyLayer,
                enclosed: activeLayer,
                minExtension: 0.13,
                direction: .horizontal
            )
        )

        let violation = result.violations.first { $0.kind == .extension }
        #expect(violation?.ruleID == "extension.POLY.drawing.ACTIVE.drawing.horizontal")
        #expect(abs((violation?.measured ?? 0) - 0.05) < 1.0e-9)
        #expect(violation?.required == 0.13)
    }

    @Test func extensionRuleAcceptsSufficientHorizontalOverhang() {
        let activeLayer = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
        let poly = shape(layer: polyLayer, x: -0.15, y: 0.0, width: 1.3, height: 0.1)
        let active = shape(layer: activeLayer, x: 0.0, y: -0.2, width: 1.0, height: 0.5)
        let result = LayoutDRCService().run(
            document: document(shapes: [poly, active]),
            tech: extensionTech(
                extending: polyLayer,
                enclosed: activeLayer,
                minExtension: 0.13,
                direction: .horizontal
            )
        )

        #expect(!result.violations.contains { $0.kind == .extension })
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
        minEnclosedArea: Double? = nil,
        requiresRectangular: Bool = false,
        allowedAngleStepDegrees: Double? = nil
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
                    minEnclosedArea: minEnclosedArea,
                    requiresRectangular: requiresRectangular,
                    allowedAngleStepDegrees: allowedAngleStepDegrees
                )
            ]
        )
    }

    private func shape(
        layer: LayoutLayerID,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        netID: UUID? = nil
    ) -> LayoutShape {
        LayoutShape(
            layer: layer,
            netID: netID,
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

    private func pairSpacingTech(
        primary: LayoutLayerID,
        secondary: LayoutLayerID,
        minSpacing: Double
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: primary), layerDefinition(id: secondary)],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: primary,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
                LayoutLayerRuleSet(
                    layerID: secondary,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ],
            spacingRules: [
                LayoutSpacingRule(
                    id: "active.nwell.spacing",
                    primaryLayer: primary,
                    secondaryLayer: secondary,
                    minSpacing: minSpacing
                )
            ]
        )
    }

    private func minimumCutTech(
        m2: LayoutLayerID,
        cut: LayoutLayerID,
        minimumCount: Int
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
                    cutSize: LayoutSize(width: 0.1, height: 0.1),
                    enclosure: LayoutViaEnclosure(top: 0, bottom: 0),
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
                LayoutLayerRuleSet(
                    layerID: cut,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ],
            minimumCutRules: [
                LayoutMinimumCutRule(
                    id: "mincut.VIA1",
                    cutLayer: cut,
                    bottomLayer: m1,
                    topLayer: m2,
                    minimumCount: minimumCount
                )
            ]
        )
    }

    private func explicitMultiCutMinimumCutTech(
        m2: LayoutLayerID,
        cut: LayoutLayerID,
        minimumCount: Int
    ) -> LayoutTechDatabase {
        var result = minimumCutTech(m2: m2, cut: cut, minimumCount: minimumCount)
        result.vias[0].layerGeometries = [
            LayoutViaLayerGeometry(layer: cut, rects: multiCutRects())
        ]
        return result
    }

    private func exactOverlapTech(
        primary: LayoutLayerID,
        secondary: LayoutLayerID
    ) -> LayoutTechDatabase {
        exactOverlapTech(primary: primary, secondaryLayers: [secondary])
    }

    private func exactOverlapTech(
        primary: LayoutLayerID,
        secondaryLayers: [LayoutLayerID]
    ) -> LayoutTechDatabase {
        let allLayers = [primary] + secondaryLayers
        return LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: allLayers.map(layerDefinition(id:)),
            vias: [],
            layerRules: allLayers.map {
                LayoutLayerRuleSet(
                    layerID: $0,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                )
            },
            exactOverlapRules: [
                LayoutExactOverlapRule(
                    id: secondaryLayers.count == 1
                        ? "exactOverlap.\(primary.name).\(secondaryLayers[0].name)"
                        : "exactOverlap.\(primary.name).oneOf.\(secondaryLayers.map(\.name).joined(separator: "."))",
                    primaryLayer: primary,
                    secondaryLayers: secondaryLayers
                )
            ]
        )
    }

    private func extensionTech(
        extending: LayoutLayerID,
        enclosed: LayoutLayerID,
        minExtension: Double,
        direction: LayoutExtensionRule.Direction
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: extending), layerDefinition(id: enclosed)],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: extending,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
                LayoutLayerRuleSet(
                    layerID: enclosed,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ],
            extensionRules: [
                LayoutExtensionRule(
                    extendingLayer: extending,
                    enclosedLayer: enclosed,
                    minExtension: minExtension,
                    direction: direction
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

    private func explicitMultiCutViaTech(
        m2: LayoutLayerID,
        cut: LayoutLayerID,
        enclosure: Double
    ) -> LayoutTechDatabase {
        var result = viaTech(m1: m1, m2: m2, cut: cut)
        result.vias[0].enclosure = LayoutViaEnclosure(top: enclosure, bottom: enclosure)
        result.vias[0].layerGeometries = [
            LayoutViaLayerGeometry(layer: cut, rects: multiCutRects()),
            LayoutViaLayerGeometry(
                layer: m1,
                rects: [LayoutRect(
                    origin: LayoutPoint(x: -0.4, y: -0.15),
                    size: LayoutSize(width: 0.8, height: 0.3)
                )]
            ),
            LayoutViaLayerGeometry(
                layer: m2,
                rects: [LayoutRect(
                    origin: LayoutPoint(x: -0.4, y: -0.15),
                    size: LayoutSize(width: 0.8, height: 0.3)
                )]
            ),
        ]
        return result
    }

    private func multiCutRects() -> [LayoutRect] {
        [
            LayoutRect(
                origin: LayoutPoint(x: -0.3, y: -0.05),
                size: LayoutSize(width: 0.1, height: 0.1)
            ),
            LayoutRect(
                origin: LayoutPoint(x: 0.2, y: -0.05),
                size: LayoutSize(width: 0.1, height: 0.1)
            ),
        ]
    }

    private func forbiddenLayerTech(_ marker: LayoutLayerID) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: marker,
                    displayName: marker.name,
                    gdsLayer: 200,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 1, green: 0, blue: 0),
                    fillPattern: .crosshatch
                )
            ],
            vias: [],
            layerRules: [],
            forbiddenLayerRules: [
                LayoutForbiddenLayerRule(
                    id: "forbiddenLayer.\(marker.name)",
                    layer: marker,
                    reason: "Generated DRC marker must be empty."
                )
            ]
        )
    }

    private func derivedDifferenceForbiddenLayerTech(
        secondary: LayoutLayerID,
        marker: LayoutLayerID
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            units: .defaultUnits,
            grid: 0.01,
            layers: [layerDefinition(id: m1), layerDefinition(id: secondary), layerDefinition(id: marker)],
            vias: [],
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
                    layerID: secondary,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 0,
                    minDensity: 0,
                    maxDensity: 1
                ),
            ],
            derivedLayerRules: [
                LayoutDerivedLayerRule(
                    id: "derived.M1_NOT_M2",
                    targetLayer: marker,
                    sourceLayers: [m1, secondary],
                    operation: .difference
                )
            ],
            forbiddenLayerRules: [
                LayoutForbiddenLayerRule(
                    id: "forbiddenLayer.\(marker.name)",
                    layer: marker,
                    reason: "Derived marker must be empty."
                )
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
