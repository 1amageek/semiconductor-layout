import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Derived layer materializer safety")
struct LayoutDerivedLayerMaterializerSafetyTests {
    @Test func pathSourceProducesBlockingDiagnostic() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let derived = LayoutLayerID(name: "M1_DERIVED", purpose: "drawing")
        let cell = LayoutCell(
            name: "top",
            shapes: [LayoutShape(
                layer: m1,
                geometry: .path(LayoutPath(
                    points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 10, y: 0)],
                    width: 1
                ))
            )]
        )
        let document = LayoutDocument(name: "path", cells: [cell], topCellID: cell.id)
        let result = LayoutDRCService().run(
            document: document,
            tech: technology(source: m1, target: derived),
            cellID: cell.id
        )

        #expect(result.violations.isEmpty)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.code == "drc.unsupported_derived_geometry")
        #expect(result.hasErrors)
    }

    @Test func nonRectilinearPolygonCheckedRunFailsClosed() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let derived = LayoutLayerID(name: "M1_DERIVED", purpose: "drawing")
        let cell = LayoutCell(
            name: "top",
            shapes: [LayoutShape(
                layer: m1,
                geometry: .polygon(LayoutPolygon(points: [
                    LayoutPoint(x: 0, y: 0),
                    LayoutPoint(x: 10, y: 0),
                    LayoutPoint(x: 0, y: 10),
                ]))
            )]
        )
        let document = LayoutDocument(name: "triangle", cells: [cell], topCellID: cell.id)

        do {
            _ = try LayoutDRCService().runChecked(
                document: document,
                tech: technology(source: m1, target: derived),
                cellID: cell.id
            )
            Issue.record("Expected unsupported derived geometry failure")
        } catch let error as LayoutDRCServiceError {
            guard case .unsupportedDerivedGeometry(let messages) = error else {
                Issue.record("Unexpected LayoutDRCServiceError: \(error)")
                return
            }
            #expect(messages.count == 1)
            #expect(messages[0].contains("non-rectilinear polygon"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func reachableChildGeometryIsCheckedBeforeDerivedMaterialization() {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let derived = LayoutLayerID(name: "M1_DERIVED", purpose: "drawing")
        let child = LayoutCell(
            name: "child",
            shapes: [LayoutShape(
                layer: m1,
                geometry: .path(LayoutPath(
                    points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 10, y: 0)],
                    width: 1
                ))
            )]
        )
        let top = LayoutCell(
            name: "top",
            instances: [LayoutInstance(cellID: child.id, name: "child0")]
        )
        let document = LayoutDocument(name: "hierarchy", cells: [top, child], topCellID: top.id)
        let result = LayoutDRCService().run(
            document: document,
            tech: technology(source: m1, target: derived),
            cellID: top.id
        )

        #expect(result.violations.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "drc.unsupported_derived_geometry" })
    }

    @Test func hierarchyCyclesAreBlockingDiagnostics() {
        let topID = UUID()
        let childID = UUID()
        let top = LayoutCell(
            id: topID,
            name: "top",
            instances: [LayoutInstance(id: UUID(), cellID: childID, name: "child0")]
        )
        let child = LayoutCell(
            id: childID,
            name: "child",
            instances: [LayoutInstance(id: UUID(), cellID: topID, name: "top0")]
        )
        let document = LayoutDocument(name: "cycle", cells: [top, child], topCellID: topID)
        let result = LayoutDRCService().run(
            document: document,
            tech: LayoutTechDatabase(grid: 0.01, layers: [], vias: [], layerRules: []),
            cellID: topID
        )

        #expect(result.violations.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "drc.hierarchy_cycle" })
    }

    private func technology(source: LayoutLayerID, target: LayoutLayerID) -> LayoutTechDatabase {
        LayoutTechDatabase(
            grid: 0.01,
            layers: [
                LayoutLayerDefinition(
                    id: source,
                    displayName: source.name,
                    gdsLayer: 1,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9)
                ),
                LayoutLayerDefinition(
                    id: target,
                    displayName: target.name,
                    gdsLayer: 2,
                    gdsDatatype: 0,
                    color: LayoutColor(red: 0.9, green: 0.5, blue: 0.3)
                ),
            ],
            vias: [],
            layerRules: [],
            derivedLayerRules: [
                LayoutDerivedLayerRule(
                    id: "derived-m1",
                    targetLayer: target,
                    sourceLayers: [source],
                    operation: .union
                ),
            ]
        )
    }
}
