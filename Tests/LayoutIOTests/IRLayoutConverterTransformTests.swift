import Foundation
import Testing
import CircuiteFoundation
import LayoutCore
import LayoutTech
import LayoutIR
@testable import LayoutIO

@Suite("IRLayoutConverter Transforms")
struct IRLayoutConverterTransformTests {

    @Test(arguments: [0, 1, 2, 3], [0.0, 90.0, 180.0, 270.0, 33.0])
    func standardTransformsPreservePhysicalPointMappings(mirrors: Int, angle: Double) throws {
        for array in [false, true] {
            let source = LayoutTransform(translation: LayoutPoint(x: 1, y: 2), rotationDegrees: angle,
                                         magnification: 1.5, mirrorX: mirrors & 1 != 0, mirrorY: mirrors & 2 != 0)
            let child = LayoutCell(name: "CHILD")
            let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "X", transform: source,
                repetition: array ? LayoutRepetition(columns: 2, rows: 2, columnStep: LayoutPoint(x: 3, y: 0),
                                                      rowStep: LayoutPoint(x: 0, y: 4)) : nil)])
            let converter = IRLayoutConverter()
            let library = try converter.exportLibrary(LayoutDocument(name: "transform", cells: [child, top], topCellID: top.id),
                                                      tech: .standard())
            let irTop = try #require(library.cells.first { $0.name == "TOP" })
            let irTransform = try #require(irTop.elements.compactMap { element -> IRTransform? in
                switch element {
                case .cellRef(let ref): return ref.transform
                case .arrayRef(let ref): return ref.transform
                default: return nil
                }
            }.first)
            let imported = try converter.checkedImportLibrary(library, tech: .standard())
            let instance = try #require(imported.cells.first { $0.name == "TOP" }?.instances.first)
            #expect(instance.occurrenceTransforms().count == (array ? 4 : 1))
            for point in [LayoutPoint(x: 1.7, y: -0.4), LayoutPoint(x: -2.5, y: 3.2), .zero] {
                let expected = source.apply(to: point)
                // Standard reflection is about the X axis, before rotation.
                let x = point.x * irTransform.magnification
                let y = point.y * irTransform.magnification * (irTransform.mirrorX ? -1 : 1)
                let radians = irTransform.angle * .pi / 180
                let standard = LayoutPoint(x: x * cos(radians) - y * sin(radians) + 1,
                                           y: x * sin(radians) + y * cos(radians) + 2)
                let restored = instance.transform.apply(to: point)
                #expect(abs(expected.x - standard.x) < 1e-10 && abs(expected.y - standard.y) < 1e-10)
                #expect(abs(expected.x - restored.x) < 1e-10 && abs(expected.y - restored.y) < 1e-10)
            }
        }
    }

    @Test("Import preserves arbitrary rotation and magnification")
    func importPreservesArbitraryRotationAndMagnification() throws {
        let library = IRLibrary(
            name: "transform-import",
            databaseUnitScale: try DatabaseUnitScale(databaseUnitsPerMicrometer: 1000),
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

        let document = try IRLayoutConverter().checkedImportLibrary(library, tech: .standard())
        let top = document.cells.first { $0.name == "TOP" }
        let instance = top?.instances.first

        #expect(instance?.transform.translation == LayoutPoint(x: 1, y: 2))
        #expect(instance?.transform.rotationDegrees == 33.0)
        #expect(instance?.transform.magnification == 1.5)
        #expect(instance?.transform.mirrorY == true)
        #expect(instance?.transform.mirrorX == false)
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

        let library = try IRLayoutConverter().exportLibrary(document, tech: .standard())
        let topCell = library.cells.first { $0.name == "TOP" }
        let cellRef = topCell?.elements.compactMap { element -> IRCellRef? in
            if case .cellRef(let ref) = element {
                return ref
            }
            return nil
        }.first

        #expect(cellRef?.origin == IRPoint(x: 1000, y: 2000))
        #expect(cellRef?.transform.angle == 213.0)
        #expect(cellRef?.transform.magnification == 1.5)
        #expect(cellRef?.transform.mirrorX == true)
    }
}
