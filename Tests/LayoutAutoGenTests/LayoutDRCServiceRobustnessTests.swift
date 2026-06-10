import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Layout DRC Service Robustness")
struct LayoutDRCServiceRobustnessTests {
    @Test func spacingDoesNotUseGridToleranceToHideViolations() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let first = rect(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let second = rect(layer: m1, x: 1.049, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(layer: m1, minSpacing: 0.05, grid: 0.01)
        )

        let violation = result.violations.first { $0.kind == .minSpacing }
        #expect(violation?.measured ?? 1 < 0.05)
        #expect(violation?.shapeIDs == [first.id, second.id])
    }

    @Test func spacingDetectsDiagonalCornerViolations() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let first = rect(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let second = rect(layer: m1, x: 1.03, y: 1.03, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [first, second]),
            tech: tech(layer: m1, minSpacing: 0.05)
        )

        let violation = result.violations.first { $0.kind == .minSpacing }
        #expect(violation?.measured ?? 1 < 0.05)
        // The marker is the localized corner gap, not the union of both shapes.
        #expect(abs((violation?.region.minX ?? 0) - 1.0) < 1.0e-9)
        #expect(abs((violation?.region.maxX ?? 0) - 1.03) < 1.0e-9)
    }

    @Test func geometryOnLayerWithoutRuleSetIsNotSilentlySkipped() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let shape = rect(layer: m1, x: 0, y: 0, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [shape]),
            tech: LayoutTechDatabase(
                grid: 0.01,
                layers: [layerDefinition(id: m1)],
                vias: [],
                layerRules: []
            )
        )

        let violation = result.violations.first { $0.kind == .ruleCoverage }
        #expect(violation?.ruleID == "layer.M1.drawing.ruleCoverage")
        #expect(violation?.shapeIDs == [shape.id])
    }

    @Test func viaEnclosureUsesGeometryInsteadOfBoundingBoxCorners() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let topTriangle = LayoutShape(
            layer: m2,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 0),
                LayoutPoint(x: 2, y: 0),
                LayoutPoint(x: 0, y: 2),
            ]))
        )
        let bottom = rect(layer: m1, x: 0, y: 0, width: 2, height: 2)
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 1))
        let result = LayoutDRCService().run(
            document: document(shapes: [topTriangle, bottom], vias: [via]),
            tech: LayoutTechDatabase(
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
                    layerRule(layer: m1),
                    layerRule(layer: m2),
                ]
            )
        )

        let violation = result.violations.first { $0.kind == .enclosure }
        #expect(violation?.viaIDs == [via.id])
        #expect(violation?.message.contains("top M2") == true)
    }

    @Test func densityUsesLocalWindowsWhenRuleSpecifiesWindow() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let dense = rect(layer: m1, x: 0, y: 0, width: 10, height: 10)
        let distant = rect(layer: m1, x: 100, y: 100, width: 1, height: 1)
        let result = LayoutDRCService().run(
            document: document(shapes: [dense, distant]),
            tech: tech(
                layer: m1,
                maxDensity: 0.5,
                densityWindow: LayoutSize(width: 10, height: 10),
                densityStep: 10
            )
        )

        let violation = result.violations.first { $0.kind == .density && ($0.measured ?? 0) > 0.5 }
        #expect(violation?.region.size == LayoutSize(width: 10, height: 10))
        #expect(violation?.measured == 1.0)
    }

    @Test func hierarchicalTerminalMappingPropagatesThroughViaStack() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.5))
        let child = LayoutCell(
            name: "STACK",
            shapes: [
                rect(layer: m1, x: 0, y: 0, width: 1, height: 1),
                rect(layer: m2, x: 0, y: 0, width: 1, height: 1),
            ],
            vias: [via],
            pins: [
                LayoutPin(name: "A", position: LayoutPoint(x: 0.5, y: 0.5), size: LayoutSize(width: 0.2, height: 0.2), layer: m1),
                LayoutPin(name: "B", position: LayoutPoint(x: 0.5, y: 0.5), size: LayoutSize(width: 0.2, height: 0.2), layer: m2),
            ]
        )
        let netID = UUID()
        let result = LayoutDRCService().run(
            document: hierarchicalDocument(child: child, terminalNetIDs: ["A": netID, "B": netID]),
            tech: stackTech(m1: m1, m2: m2, cut: cut)
        )

        #expect(!result.violations.contains { $0.kind == .disconnectedOpen })
        #expect(!result.violations.contains { $0.kind == .overlapShort })
    }

    @Test func conflictingHierarchicalTerminalMappingAcrossViaStackIsShort() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let cut = LayoutLayerID(name: "VIA1", purpose: "cut")
        let child = LayoutCell(
            name: "STACK",
            shapes: [
                rect(layer: m1, x: 0, y: 0, width: 1, height: 1),
                rect(layer: m2, x: 0, y: 0, width: 1, height: 1),
            ],
            vias: [LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 0.5, y: 0.5))],
            pins: [
                LayoutPin(name: "A", position: LayoutPoint(x: 0.5, y: 0.5), size: LayoutSize(width: 0.2, height: 0.2), layer: m1),
                LayoutPin(name: "B", position: LayoutPoint(x: 0.5, y: 0.5), size: LayoutSize(width: 0.2, height: 0.2), layer: m2),
            ]
        )
        let firstNet = UUID()
        let secondNet = UUID()
        let result = LayoutDRCService().run(
            document: hierarchicalDocument(child: child, terminalNetIDs: ["A": firstNet, "B": secondNet]),
            tech: stackTech(m1: m1, m2: m2, cut: cut)
        )

        let violation = result.violations.first { $0.ruleID == "connectivity.short.terminalComponent" }
        #expect(violation?.kind == .overlapShort)
        #expect(Set(violation?.netIDs ?? []) == Set([firstNet, secondNet]))
    }

    private func document(shapes: [LayoutShape], vias: [LayoutVia] = []) -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: shapes, vias: vias)
        return LayoutDocument(name: "drc-robustness", cells: [cell], topCellID: cell.id)
    }

    private func hierarchicalDocument(child: LayoutCell, terminalNetIDs: [String: UUID]) -> LayoutDocument {
        let top = LayoutCell(
            name: "TOP",
            instances: [
                LayoutInstance(cellID: child.id, name: "X1", terminalNetIDs: terminalNetIDs),
            ]
        )
        return LayoutDocument(name: "hierarchical-drc", cells: [top, child], topCellID: top.id)
    }

    private func rect(
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

    private func tech(
        layer: LayoutLayerID,
        minSpacing: Double = 0,
        maxDensity: Double = 1,
        densityWindow: LayoutSize? = nil,
        densityStep: Double? = nil,
        grid: Double = 0.01
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
            grid: grid,
            layers: [layerDefinition(id: layer)],
            vias: [],
            layerRules: [
                layerRule(
                    layer: layer,
                    minSpacing: minSpacing,
                    maxDensity: maxDensity,
                    densityWindow: densityWindow,
                    densityStep: densityStep
                )
            ]
        )
    }

    private func layerRule(
        layer: LayoutLayerID,
        minSpacing: Double = 0,
        maxDensity: Double = 1,
        densityWindow: LayoutSize? = nil,
        densityStep: Double? = nil
    ) -> LayoutLayerRuleSet {
        LayoutLayerRuleSet(
            layerID: layer,
            minWidth: 0,
            minSpacing: minSpacing,
            minArea: 0,
            minDensity: 0,
            maxDensity: maxDensity,
            densityWindow: densityWindow,
            densityStep: densityStep
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

    private func stackTech(
        m1: LayoutLayerID,
        m2: LayoutLayerID,
        cut: LayoutLayerID
    ) -> LayoutTechDatabase {
        LayoutTechDatabase(
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
                ),
            ],
            layerRules: [
                layerRule(layer: m1),
                layerRule(layer: m2),
            ]
        )
    }
}
