import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Derived layer identity")
struct LayoutDerivedLayerMaterializerIdentityTests {
    @Test func repeatedMaterializationProducesStableDerivedShapeIDs() {
        let sourceLayer = LayoutLayerID(name: "M1", purpose: "drawing")
        let targetLayer = LayoutLayerID(name: "M1_MARK", purpose: "drawing")
        let source = LayoutShape(
            layer: sourceLayer,
            geometry: .rect(LayoutRect(origin: LayoutPoint(x: 0, y: 0), size: LayoutSize(width: 1, height: 1)))
        )
        let cell = LayoutCell(name: "top", shapes: [source])
        let document = LayoutDocument(name: "identity", cells: [cell])
        let technology = LayoutTechDatabase(
            grid: 0.01,
            layers: [],
            vias: [],
            layerRules: [],
            derivedLayerRules: [LayoutDerivedLayerRule(
                id: "mark",
                targetLayer: targetLayer,
                sourceLayers: [sourceLayer],
                operation: .union
            )]
        )

        let first = LayoutDerivedLayerMaterializer().materialize(document: document, tech: technology)
        let second = LayoutDerivedLayerMaterializer().materialize(document: document, tech: technology)
        let firstIDs = first.cells.flatMap(\.shapes).filter { $0.properties["derivedLayerRuleID"] != nil }.map(\.id)
        let secondIDs = second.cells.flatMap(\.shapes).filter { $0.properties["derivedLayerRuleID"] != nil }.map(\.id)
        #expect(firstIDs == secondIDs)
        #expect(firstIDs.count == 1)
    }
}
