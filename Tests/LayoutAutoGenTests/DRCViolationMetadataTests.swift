import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("DRC Violation Metadata")
struct DRCViolationMetadataTests {

    @Test("DRC violations include rule metadata and measurements")
    func violationIncludesRuleMetadataAndMeasurements() {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let shape = LayoutShape(
            layer: m1ID,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 0.5, height: 1.0)
            ))
        )
        let document = document(shapes: [shape])
        let tech = LayoutTechDatabase(
            units: .defaultUnits,
            layers: [layerDefinition(id: m1ID)],
            vias: [],
            layerRules: [
                LayoutLayerRuleSet(
                    layerID: m1ID,
                    minWidth: 0,
                    minSpacing: 0,
                    minArea: 1.0,
                    minDensity: 0,
                    maxDensity: 1
                )
            ]
        )

        let result = LayoutDRCService().run(document: document, tech: tech)
        let violation = result.violations.first { $0.kind == .minArea }

        #expect(violation?.ruleID == "layer.M1.drawing.minArea")
        #expect(violation?.severity == .error)
        #expect(violation?.measured == 0.5)
        #expect(violation?.required == 1.0)
        #expect(violation?.unit == "um2")
        #expect(violation?.shapeIDs == [shape.id])
        #expect(violation?.suggestedFix != nil)
    }

    @Test("Connectivity violations carry shape and net evidence")
    func connectivityViolationCarriesEvidence() {
        let m1ID = LayoutLayerID(name: "M1", purpose: "drawing")
        let firstNet = UUID()
        let secondNet = UUID()
        let first = LayoutShape(
            layer: m1ID,
            netID: firstNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 1, height: 1)
            ))
        )
        let second = LayoutShape(
            layer: m1ID,
            netID: secondNet,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0.5, y: 0.5),
                size: LayoutSize(width: 1, height: 1)
            ))
        )
        let document = document(shapes: [first, second])
        let tech = LayoutTechDatabase(
            units: .defaultUnits,
            layers: [layerDefinition(id: m1ID)],
            vias: [],
            layerRules: []
        )

        let result = LayoutDRCService().run(document: document, tech: tech)
        let violation = result.violations.first { $0.kind == .overlapShort }

        #expect(violation?.ruleID == "connectivity.short.sameLayerOverlap")
        #expect(violation?.shapeIDs == [first.id, second.id])
        #expect(violation?.netIDs == [firstNet, secondNet])
        #expect(violation?.suggestedFix != nil)
    }

    @Test("DRC result separates errors from warnings")
    func resultSeparatesErrorsFromWarnings() {
        let warningOnly = LayoutDRCResult(violations: [
            LayoutViolation(
                kind: .density,
                severity: .warning,
                message: "Density warning"
            )
        ])
        let withError = LayoutDRCResult(violations: [
            LayoutViolation(
                kind: .minWidth,
                severity: .error,
                message: "Width error"
            )
        ])

        #expect(warningOnly.hasViolations)
        #expect(warningOnly.hasWarnings)
        #expect(!warningOnly.hasErrors)
        #expect(withError.hasErrors)
    }

    private func document(shapes: [LayoutShape]) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes)
        return LayoutDocument(name: "drc-metadata", cells: [cell], topCellID: cell.id)
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
