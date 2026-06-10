import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutIR
@testable import LayoutIO

@Suite("IRLayoutBridge Vias")
struct IRLayoutBridgeViaTests {

    @Test("Export materializes vias as cut-layer boundaries")
    func exportMaterializesViasAsCutLayerBoundaries() {
        let via = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 1.0, y: 2.0)
        )
        let top = LayoutCell(name: "TOP", vias: [via])
        let document = LayoutDocument(name: "via-export", cells: [top], topCellID: top.id)

        let library = IRLayoutBridge().exportLibrary(document, tech: .standard())
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
    func importRestoresBridgeAuthoredViaBoundariesAsVias() {
        let originalVia = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 1.0, y: 2.0)
        )
        let top = LayoutCell(name: "TOP", vias: [originalVia])
        let document = LayoutDocument(name: "via-round-trip", cells: [top], topCellID: top.id)
        let bridge = IRLayoutBridge()

        let library = bridge.exportLibrary(document, tech: .standard())
        let imported = bridge.importLibrary(library, tech: .standard())
        let importedTop = imported.cells.first

        #expect(importedTop?.vias.count == 1)
        #expect(importedTop?.shapes.isEmpty == true)
        #expect(importedTop?.vias.first?.viaDefinitionID == "VIA1")
        #expect(approximatelyEqual(importedTop?.vias.first?.position.x, 1.0))
        #expect(approximatelyEqual(importedTop?.vias.first?.position.y, 2.0))
    }

    @Test("Import leaves unmarked cut boundaries as geometry")
    func importLeavesUnmarkedCutBoundariesAsGeometry() {
        let library = IRLibrary(
            name: "unmarked-cut",
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

        let document = IRLayoutBridge().importLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.isEmpty == true)
        #expect(top?.shapes.count == 1)
    }

    @Test("Import restores OASIS-style named via properties")
    func importRestoresOASISStyleNamedViaProperties() {
        let library = IRLibrary(
            name: "oasis-style-via",
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

        let document = IRLayoutBridge().importLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.count == 1)
        #expect(top?.shapes.isEmpty == true)
        #expect(top?.vias.first?.viaDefinitionID == "VIA1")
        #expect(approximatelyEqual(top?.vias.first?.position.x, 1.0))
        #expect(approximatelyEqual(top?.vias.first?.position.y, 2.0))
    }

    @Test("Import leaves marked boundaries on non-cut layers as geometry")
    func importLeavesMarkedBoundariesOnNonCutLayersAsGeometry() {
        let library = IRLibrary(
            name: "marked-non-cut",
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

        let document = IRLayoutBridge().importLibrary(library, tech: .standard())
        let top = document.cells.first

        #expect(top?.vias.isEmpty == true)
        #expect(top?.shapes.count == 1)
    }

    @Test("Export skips vias whose cut layer is not mapped")
    func exportSkipsViasWhoseCutLayerIsNotMapped() {
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

        let library = IRLayoutBridge().exportLibrary(document, tech: tech)

        #expect(library.cells.first?.elements.isEmpty == true)
    }

    private func approximatelyEqual(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= 1e-12
    }
}
