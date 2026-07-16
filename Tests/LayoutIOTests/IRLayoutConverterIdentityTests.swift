import Testing
import CircuiteFoundation
import LayoutCore
import LayoutIO
import LayoutIR
import LayoutTech

@Suite("IR layout identity")
struct IRLayoutConverterIdentityTests {
    @Test func repeatedImportKeepsCellAndShapeIDsStable() throws {
        let library = IRLibrary(
            name: "identity",
            databaseUnitScale: try DatabaseUnitScale(databaseUnitsPerMicrometer: 1000),
            cells: [
                IRCell(name: "child", elements: []),
                IRCell(
                    name: "top",
                    elements: [
                        .boundary(IRBoundary(
                            layer: 1,
                            datatype: 0,
                            points: [
                                IRPoint(x: 0, y: 0),
                                IRPoint(x: 100, y: 0),
                                IRPoint(x: 100, y: 100),
                                IRPoint(x: 0, y: 100),
                                IRPoint(x: 0, y: 0),
                            ],
                            properties: []
                        )),
                        .cellRef(IRCellRef(cellName: "child", origin: IRPoint(x: 25, y: 25)))
                    ]
                )
            ]
        )
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let tech = LayoutTechDatabase(
            grid: 0.001,
            layers: [LayoutLayerDefinition(
                id: layer,
                displayName: "M1",
                gdsLayer: 1,
                gdsDatatype: 0,
                color: .gray
            )],
            vias: [],
            layerRules: []
        )
        let converter = IRLayoutConverter()
        let first = try converter.checkedImportLibrary(library, tech: tech)
        let second = try converter.checkedImportLibrary(library, tech: tech)
        #expect(first.cells.map(\.id) == second.cells.map(\.id))
        #expect(first.cells.flatMap(\.shapes).map(\.id) == second.cells.flatMap(\.shapes).map(\.id))
        #expect(first.cells.flatMap(\.instances).map(\.id) == second.cells.flatMap(\.instances).map(\.id))
    }
}
