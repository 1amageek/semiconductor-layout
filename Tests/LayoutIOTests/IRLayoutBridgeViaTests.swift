import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutIR
@testable import LayoutIO

@Suite("IRLayoutBridge Vias")
struct IRLayoutBridgeViaTests {

    @Test("Cell properties round trip through IR cells")
    func cellPropertiesRoundTripThroughIRCells() throws {
        let cell = LayoutCell(
            name: "TOP",
            properties: [
                "FIXED_BBOX": "0 0 10 5",
                "lsi.intent": "abutment-box"
            ]
        )
        let document = LayoutDocument(name: "cell-properties", cells: [cell], topCellID: cell.id)
        let bridge = IRLayoutBridge()

        let library = try bridge.exportLibrary(document, tech: .standard())
        let irCell = try #require(library.cells.first)
        #expect(irCell.properties.contains { $0.attribute == 0 && $0.value == "FIXED_BBOX=0 0 10 5" })
        #expect(irCell.properties.contains { $0.attribute == 0 && $0.value == "lsi.intent=abutment-box" })

        let imported = try bridge.checkedImportLibrary(library, tech: .standard())
        let importedTop = try #require(imported.cells.first)
        #expect(importedTop.properties == cell.properties)
    }

    @Test("Opaque IR cell properties are preserved with synthetic keys")
    func opaqueIRCellPropertiesArePreservedWithSyntheticKeys() throws {
        let library = IRLibrary(
            name: "opaque-cell-properties",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(
                    name: "TOP",
                    properties: [
                        IRProperty(attribute: 7, value: "opaque"),
                        IRProperty(attribute: 7, value: "second"),
                        IRProperty(attribute: 0, value: "lsi.fixedBBox=0 0 1 1"),
                    ]
                ),
            ]
        )
        let bridge = IRLayoutBridge()

        let imported = try bridge.checkedImportLibrary(library, tech: .standard())
        let importedTop = try #require(imported.cells.first)

        #expect(importedTop.properties["lsi.fixedBBox"] == "0 0 1 1")
        #expect(importedTop.properties["property.7"] == "opaque")
        #expect(importedTop.properties["property.7.1"] == "second")
    }

    @Test("Export materializes vias as cut-layer boundaries")
    func exportMaterializesViasAsCutLayerBoundaries() throws {
        let via = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 1.0, y: 2.0)
        )
        let top = LayoutCell(name: "TOP", vias: [via])
        let document = LayoutDocument(name: "via-export", cells: [top], topCellID: top.id)

        let library = try IRLayoutBridge().exportLibrary(document, tech: .standard())
        let boundaries = library.cells.first?.elements.compactMap { element -> IRBoundary? in
            if case .boundary(let boundary) = element {
                return boundary
            }
            return nil
        } ?? []

        #expect(boundaries.count == 1)
        #expect(boundaries.first?.layer == 3)
        #expect(boundaries.first?.datatype == 0)
        #expect(boundaries.first?.properties.contains {
            $0.attribute == 7301 && $0.value == "lsi.viaDefinition=VIA1"
        } == true)
        #expect(boundaries.first?.points == [
            IRPoint(x: 975, y: 1975),
            IRPoint(x: 1025, y: 1975),
            IRPoint(x: 1025, y: 2025),
            IRPoint(x: 975, y: 2025),
            IRPoint(x: 975, y: 1975),
        ])
    }

    @Test("Import restores bridge-authored via boundaries as vias")
    func importRestoresBridgeAuthoredViaBoundariesAsVias() throws {
        let originalVia = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 1.0, y: 2.0)
        )
        let top = LayoutCell(name: "TOP", vias: [originalVia])
        let document = LayoutDocument(name: "via-round-trip", cells: [top], topCellID: top.id)
        let bridge = IRLayoutBridge()

        let library = try bridge.exportLibrary(document, tech: .standard())
        let imported = try bridge.checkedImportLibrary(library, tech: .standard())
        let importedTop = imported.cells.first

        #expect(importedTop?.vias.count == 1)
        #expect(importedTop?.shapes.isEmpty == true)
        #expect(importedTop?.vias.first?.viaDefinitionID == "VIA1")
        #expect(approximatelyEqual(importedTop?.vias.first?.position.x, 1.0))
        #expect(approximatelyEqual(importedTop?.vias.first?.position.y, 2.0))
    }

    @Test("Import leaves unmarked cut boundaries as geometry")
    func importLeavesUnmarkedCutBoundariesAsGeometry() throws {
        let library = IRLibrary(
            name: "unmarked-cut",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .boundary(IRBoundary(
                        layer: 3,
                        datatype: 0,
                        points: [
                            IRPoint(x: 975, y: 1975),
                            IRPoint(x: 1025, y: 1975),
                            IRPoint(x: 1025, y: 2025),
                            IRPoint(x: 975, y: 2025),
                            IRPoint(x: 975, y: 1975),
                        ]
                    ))
                ])
            ]
        )

        let document = try IRLayoutBridge().checkedImportLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.isEmpty == true)
        #expect(top?.shapes.count == 1)
    }

    @Test("Import restores OASIS-style named via properties")
    func importRestoresOASISStyleNamedViaProperties() throws {
        let library = IRLibrary(
            name: "oasis-style-via",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .boundary(IRBoundary(
                        layer: 3,
                        datatype: 0,
                        points: [
                            IRPoint(x: 975, y: 1975),
                            IRPoint(x: 1025, y: 1975),
                            IRPoint(x: 1025, y: 2025),
                            IRPoint(x: 975, y: 2025),
                            IRPoint(x: 975, y: 1975),
                        ],
                        properties: [
                            IRProperty(attribute: 0, value: "lsi.viaDefinition=VIA1")
                        ]
                    ))
                ])
            ]
        )

        let document = try IRLayoutBridge().checkedImportLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.count == 1)
        #expect(top?.shapes.isEmpty == true)
        #expect(top?.vias.first?.viaDefinitionID == "VIA1")
        #expect(approximatelyEqual(top?.vias.first?.position.x, 1.0))
        #expect(approximatelyEqual(top?.vias.first?.position.y, 2.0))
    }

    @Test("Import leaves marked boundaries on non-cut layers as geometry")
    func importLeavesMarkedBoundariesOnNonCutLayersAsGeometry() throws {
        let library = IRLibrary(
            name: "marked-non-cut",
            databaseUnitScale: LayoutTechDatabase.standard().units.scale,
            cells: [
                IRCell(name: "TOP", elements: [
                    .boundary(IRBoundary(
                        layer: 1,
                        datatype: 0,
                        points: [
                            IRPoint(x: 975, y: 1975),
                            IRPoint(x: 1025, y: 1975),
                            IRPoint(x: 1025, y: 2025),
                            IRPoint(x: 975, y: 2025),
                            IRPoint(x: 975, y: 1975),
                        ],
                        properties: [
                            IRProperty(attribute: 7301, value: "lsi.viaDefinition=VIA1")
                        ]
                    ))
                ])
            ]
        )

        let document = try IRLayoutBridge().checkedImportLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.isEmpty == true)
        #expect(top?.shapes.count == 1)
    }

    @Test("Export rejects vias whose cut layer is not mapped")
    func exportRejectsViasWhoseCutLayerIsNotMapped() throws {
        let m1 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M1", purpose: "drawing"),
            displayName: "Metal1",
            gdsLayer: 1,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.3, green: 0.5, blue: 0.9),
            fillPattern: .solid
        )
        let m2 = LayoutLayerDefinition(
            id: LayoutLayerID(name: "M2", purpose: "drawing"),
            displayName: "Metal2",
            gdsLayer: 2,
            gdsDatatype: 0,
            color: LayoutColor(red: 0.9, green: 0.5, blue: 0.3),
            fillPattern: .solid
        )
        let tech = LayoutTechDatabase(
            layers: [m1, m2],
            vias: [
                LayoutViaDefinition(
                    id: "BROKEN_VIA",
                    cutLayer: LayoutLayerID(name: "CUT", purpose: "cut"),
                    topLayer: m2.id,
                    bottomLayer: m1.id,
                    cutSize: LayoutSize(width: 0.05, height: 0.05),
                    enclosure: LayoutViaEnclosure(top: 0.01, bottom: 0.01),
                    cutSpacing: 0.05
                )
            ],
            layerRules: []
        )
        let top = LayoutCell(
            name: "TOP",
            vias: [
                LayoutVia(viaDefinitionID: "BROKEN_VIA", position: LayoutPoint(x: 1.0, y: 2.0))
            ]
        )
        let document = LayoutDocument(name: "missing-cut-layer", cells: [top], topCellID: top.id)

        #expect(throws: LayoutIOError.self) {
            _ = try IRLayoutBridge().exportLibrary(document, tech: tech)
        }
    }

    private func approximatelyEqual(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= 1e-12
    }
}
