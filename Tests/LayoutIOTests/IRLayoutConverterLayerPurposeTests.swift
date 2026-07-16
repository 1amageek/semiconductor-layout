import Foundation
import LayoutCore
import LayoutIR
import LayoutTech
import Testing
@testable import LayoutIO

@Suite("IRLayoutConverter layer purposes")
struct IRLayoutConverterLayerPurposeTests {
    private let drawing = LayoutLayerID(name: "met1", purpose: "drawing")
    private let label = LayoutLayerID(name: "met1", purpose: "label")
    private let pin = LayoutLayerID(name: "met1", purpose: "pin")

    @Test("Geometry and labels use distinct foundry GDS purposes")
    func geometryAndLabelsUseDistinctFoundryGDSPurposes() throws {
        let tech = technology()
        let cell = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: drawing,
                    geometry: .rect(LayoutRect(
                        origin: .zero,
                        size: LayoutSize(width: 1, height: 1)
                    ))
                )
            ],
            labels: [
                LayoutLabel(text: "out", position: LayoutPoint(x: 0.5, y: 0.5), layer: drawing)
            ]
        )
        let document = LayoutDocument(name: "purpose", cells: [cell], topCellID: cell.id)

        let library = try IRLayoutConverter().exportLibrary(document, tech: tech)
        let exportedCell = try #require(library.cells.first)
        let boundary = try #require(exportedCell.elements.compactMap { element -> IRBoundary? in
            guard case .boundary(let boundary) = element else { return nil }
            return boundary
        }.first)
        let text = try #require(exportedCell.elements.compactMap { element -> IRText? in
            guard case .text(let text) = element else { return nil }
            return text
        }.first)

        #expect(boundary.layer == 68)
        #expect(boundary.datatype == 20)
        #expect(text.layer == 68)
        #expect(text.texttype == 5)

        let imported = try IRLayoutConverter().checkedImportLibrary(library, tech: tech)
        let importedCell = try #require(imported.cells.first)
        #expect(importedCell.shapes.first?.layer == drawing)
        #expect(importedCell.labels.first?.layer == drawing)
    }

    @Test("Duplicate layer identifiers fail instead of changing export meaning by order")
    func duplicateLayerIdentifiersFail() throws {
        var tech = technology()
        tech.layers.append(LayoutLayerDefinition(
            id: drawing,
            displayName: "Duplicate Metal1",
            gdsLayer: 168,
            gdsDatatype: 20,
            color: .gray
        ))
        let cell = LayoutCell(name: "TOP")
        let document = LayoutDocument(name: "duplicate", cells: [cell], topCellID: cell.id)

        do {
            _ = try IRLayoutConverter().exportLibrary(document, tech: tech)
            Issue.record("Expected duplicate layer identifier rejection")
        } catch let LayoutIOError.conversionFailed(message) {
            #expect(message.contains("duplicate layer identifier 'met1/drawing'"))
        }
    }

    private func technology() -> LayoutTechDatabase {
        LayoutTechDatabase(
            grid: 0.005,
            layers: [
                LayoutLayerDefinition(
                    id: drawing,
                    displayName: "Metal1",
                    gdsLayer: 68,
                    gdsDatatype: 20,
                    color: .gray
                ),
                LayoutLayerDefinition(
                    id: label,
                    displayName: "Metal1 Label",
                    gdsLayer: 68,
                    gdsDatatype: 5,
                    color: .gray
                ),
                LayoutLayerDefinition(
                    id: pin,
                    displayName: "Metal1 Pin",
                    gdsLayer: 68,
                    gdsDatatype: 16,
                    color: .gray
                ),
            ],
            vias: [],
            layerRules: []
        )
    }
}
