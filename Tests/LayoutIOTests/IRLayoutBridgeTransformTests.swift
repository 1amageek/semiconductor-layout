import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutIR
@testable import LayoutIO

@Suite("IRLayoutBridge Transforms")
struct IRLayoutBridgeTransformTests {

    @Test("Import preserves arbitrary rotation and magnification")
    func importPreservesArbitraryRotationAndMagnification() throws {
        let library = IRLibrary(
            name: "transform-import",
            cells: [
                IRCell(name: "CHILD"),
                IRCell(name: "TOP", elements: [
                    .cellRef(IRCellRef(
                        cellName: "CHILD",
                        origin: IRPoint(x: 1000, y: 2000),
                        transform: IRTransform(mirrorX: true, magnification: 1.5, angle: 33.0)
                    ))
                ])
            ]
        )

        let document = try IRLayoutBridge().checkedImportLibrary(library, tech: .standard())
        let top = document.cells.first { $0.name == "TOP" }
        let instance = top?.instances.first

        #expect(instance?.transform.translation == LayoutPoint(x: 1, y: 2))
        #expect(instance?.transform.rotationDegrees == 33.0)
        #expect(instance?.transform.magnification == 1.5)
        #expect(instance?.transform.mirrorX == true)
    }

    @Test("Export preserves arbitrary rotation and magnification")
    func exportPreservesArbitraryRotationAndMagnification() throws {
        let child = LayoutCell(name: "CHILD")
        let instance = LayoutInstance(
            cellID: child.id,
            name: "I0",
            transform: LayoutTransform(
                translation: LayoutPoint(x: 1, y: 2),
                rotationDegrees: 33.0,
                magnification: 1.5,
                mirrorX: true
            )
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        let document = LayoutDocument(
            name: "transform-export",
            cells: [child, top],
            topCellID: top.id
        )

        let library = try IRLayoutBridge().exportLibrary(document, tech: .standard())
        let topCell = library.cells.first { $0.name == "TOP" }
        let cellRef = topCell?.elements.compactMap { element -> IRCellRef? in
            if case .cellRef(let ref) = element {
                return ref
            }
            return nil
        }.first

        #expect(cellRef?.origin == IRPoint(x: 1000, y: 2000))
        #expect(cellRef?.transform.angle == 33.0)
        #expect(cellRef?.transform.magnification == 1.5)
        #expect(cellRef?.transform.mirrorX == true)
    }
}
