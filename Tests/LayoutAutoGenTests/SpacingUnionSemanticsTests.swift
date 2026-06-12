import Foundation
import Testing
import LayoutCore
import LayoutTech
@testable import LayoutVerify

/// Spacing is a property of the MERGED metal, not of the input rects: a
/// route polyline whose legs overlap each other and the bar they launch
/// from must read as one feature. The band-decomposed kernel once
/// flagged the leg/bar overlaps and the leg1↔leg3 gap that leg2 fills
/// as sub-minimum "spacing" (false positives the editor's finish-net
/// gate then trusted, blocking every auto-route).
@Suite("Spacing union semantics", .timeLimit(.minutes(2)))
struct SpacingUnionSemanticsTests {
    @Test func routeLegsOverBarAreOneFeature() throws {
        let tech = LayoutTechDatabase.sampleProcess()
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        var cell = LayoutCell(name: "T")
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutShape {
            LayoutShape(layer: m1, geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: x, y: y),
                size: LayoutSize(width: w, height: h)
            )))
        }
        cell.shapes = [
            rect(1.08, 0.0, 0.34, 2.0),          // drain bar
            rect(1.305, 1.885, 23.46, 0.23),     // leg1 horizontal
            rect(24.535, 1.885, 0.23, 0.58),     // leg2 vertical
            rect(24.535, 2.235, 1.12, 0.23),     // leg3 horizontal
        ]
        let document = LayoutDocument(name: "t", cells: [cell], topCellID: cell.id)
        let violations = LayoutDRCService().run(document: document, tech: tech)
            .violations
            .filter { $0.kind == .minSpacing }
        #expect(violations.isEmpty, "\(violations.map(\.message))")
    }
}
