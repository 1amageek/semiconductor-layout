import Testing
import LayoutCore
import LayoutIO
import LayoutIR
import LayoutTech

@Suite("IRLayoutBridge ArrayRef")
struct IRLayoutBridgeArrayRefTests {
    @Test func importsArrayRefAsRepetitionAndExportsArrayRef() throws {
        let child = IRCell(name: "UNIT")
        let top = IRCell(name: "TOP", elements: [
            .arrayRef(IRArrayRef(
                cellName: "UNIT",
                transform: .identity,
                columns: 4,
                rows: 3,
                referencePoints: [
                    IRPoint(x: 100, y: 200),
                    IRPoint(x: 4100, y: 200),
                    IRPoint(x: 100, y: 3200),
                ]
            ))
        ])
        let library = IRLibrary(
            name: "AREF",
            units: IRUnits(dbuPerMicron: 1000),
            cells: [child, top]
        )

        let bridge = IRLayoutBridge()
        let document = try bridge.checkedImportLibrary(library, tech: .standard())
        let topCell = document.cells.first { $0.name == "TOP" }
        let instance = topCell?.instances.first

        #expect(topCell?.instances.count == 1)
        #expect(instance?.repetition?.columns == 4)
        #expect(instance?.repetition?.rows == 3)
        #expect(instance?.transform.translation == LayoutPoint(x: 0.1, y: 0.2))
        #expect(instance?.repetition?.columnStep == LayoutPoint(x: 1, y: 0))
        #expect(instance?.repetition?.rowStep == LayoutPoint(x: 0, y: 1))

        let exported = try bridge.exportLibrary(document, tech: .standard())
        let exportedTop = exported.cells.first { $0.name == "TOP" }
        guard case .arrayRef(let array)? = exportedTop?.elements.first else {
            Issue.record("Expected a single arrayRef after round-trip")
            return
        }

        #expect(array.columns == 4)
        #expect(array.rows == 3)
        #expect(array.referencePoints == [
            IRPoint(x: 100, y: 200),
            IRPoint(x: 4100, y: 200),
            IRPoint(x: 100, y: 3200),
        ])
    }

    @Test func exportRefusesRepetitionBeyondGDSColumnLimit() {
        let child = LayoutCell(name: "UNIT")
        let instance = LayoutInstance(
            cellID: child.id,
            name: "XA",
            repetition: LayoutRepetition(
                columns: Int(Int16.max) + 1,
                rows: 1,
                columnStep: LayoutPoint(x: 1, y: 0),
                rowStep: LayoutPoint(x: 0, y: 1)
            )
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(name: "huge", cells: [child, top], topCellID: top.id)

        #expect(throws: LayoutIOError.self) {
            try IRLayoutBridge().exportLibrary(document, tech: .standard())
        }
    }
}
