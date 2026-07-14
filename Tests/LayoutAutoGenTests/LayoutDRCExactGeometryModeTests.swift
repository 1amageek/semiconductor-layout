import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutVerify

@Suite("Layout DRC exact geometry mode")
struct LayoutDRCExactGeometryModeTests {
    @Test func exactOnlyRunBlocksPathGeometry() {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let shape = LayoutShape(
            layer: layer,
            geometry: .path(LayoutPath(
                points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 2, y: 1)],
                width: 0.2
            ))
        )
        let document = LayoutDocument(
            name: "path",
            cells: [LayoutCell(name: "top", shapes: [shape])]
        )
        let topCellID = document.cells[0].id
        let result = LayoutDRCService().run(
            document: document,
            tech: LayoutTechDatabase(grid: 0.01, layers: [], vias: [], layerRules: []),
            cellID: topCellID,
            geometryMode: .exactOnly
        )

        #expect(result.violations.isEmpty)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].code == "drc.unsupported_exact_geometry")
        #expect(result.diagnostics[0].severity == .error)
    }

    @Test func developmentModeRetainsExploratoryPathEvaluation() {
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let shape = LayoutShape(
            layer: layer,
            geometry: .path(LayoutPath(
                points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 2, y: 1)],
                width: 0.2
            ))
        )
        let document = LayoutDocument(
            name: "path",
            cells: [LayoutCell(name: "top", shapes: [shape])]
        )
        let result = LayoutDRCService().run(
            document: document,
            tech: LayoutTechDatabase(grid: 0.01, layers: [], vias: [], layerRules: []),
            geometryMode: .development
        )

        #expect(result.diagnostics.isEmpty)
    }
}
