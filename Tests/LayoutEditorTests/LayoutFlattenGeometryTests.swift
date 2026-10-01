import LayoutCore
import Testing
@testable import LayoutEditor

@Suite("Editor flatten geometry", .timeLimit(.minutes(1)))
@MainActor
struct LayoutFlattenGeometryTests {
    @Test func editorFlattenRetainsViaPoseAndPinExtents() throws {
        let via = LayoutVia(viaDefinitionID: "VIA1", position: LayoutPoint(x: 1, y: 2))
        let child = LayoutCell(name: "CHILD", vias: [via], pins: [LayoutPin(name: "P", position: via.position,
                               size: LayoutSize(width: 2, height: 0.5), layer: LayoutLayerID(name: "M1", purpose: "drawing"))])
        let transform = LayoutTransform(rotation: .deg90, magnification: 2, mirrorX: true)
        var content = LayoutEditorViewModel.FlattenedContent()
        LayoutEditorViewModel.collectFlattenedContent(of: child,
            in: LayoutDocument(name: "editor", cells: [child], topCellID: child.id),
            transforms: [transform], depth: 0, into: &content)
        let actual = try #require(content.vias.first)
        #expect(actual.position == via.transformed(by: [transform]).position)
        #expect(actual.geometryTransforms == via.transformed(by: [transform]).geometryTransforms)
        #expect(content.pins.first?.size == LayoutSize(width: 1, height: 4))
    }
}
