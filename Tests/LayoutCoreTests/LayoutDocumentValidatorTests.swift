import Foundation
import Testing
@testable import LayoutCore

@Suite("Layout document validator")
struct LayoutDocumentValidatorTests {
    @Test("valid hierarchy and geometry pass structural validation")
    func validDocumentPasses() throws {
        let fixture = try makeFixture()
        let report = LayoutDocumentValidator().validate(fixture)

        #expect(report.isValid)
        #expect(report.errors.isEmpty)
    }

    @Test("missing references and nonfinite geometry are typed findings")
    func invalidReferencesAndGeometryFail() throws {
        var fixture = try makeFixture()
        let missingNet = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000099")
        )
        fixture.cells[1].shapes[0].netID = missingNet
        fixture.cells[1].shapes[0].geometry = .rect(
            LayoutRect(
                origin: LayoutPoint(x: .infinity, y: 0),
                size: LayoutSize(width: 1, height: 1)
            )
        )
        let report = LayoutDocumentValidator().validate(fixture)

        #expect(!report.isValid)
        #expect(report.findings.contains {
            $0.code == "layout.shape.net-missing"
        })
        #expect(report.findings.contains {
            $0.code == "layout.geometry.coordinate-invalid"
        })
    }

    @Test("hierarchy cycles fail structural validation")
    func hierarchyCycleFails() throws {
        var fixture = try makeFixture()
        let child = fixture.cells[0]
        fixture.cells[0].instances = [
            LayoutInstance(cellID: fixture.cells[1].id, name: "parent-loop"),
        ]
        fixture.cells[1].instances = [
            LayoutInstance(cellID: child.id, name: "child-loop"),
        ]
        let report = LayoutDocumentValidator().validate(fixture)

        #expect(!report.isValid)
        #expect(report.findings.contains { $0.code == "layout.hierarchy.cycle" })
    }

    private func makeFixture() throws -> LayoutDocument {
        let childID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let topID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let netID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")
        )
        let shapeID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")
        )
        let instanceID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000005")
        )
        let child = LayoutCell(id: childID, name: "device")
        let top = LayoutCell(
            id: topID,
            name: "top",
            shapes: [
                LayoutShape(
                    id: shapeID,
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    netID: netID,
                    geometry: .rect(
                        LayoutRect(
                            origin: .zero,
                            size: LayoutSize(width: 1, height: 1)
                        )
                    )
                ),
            ],
            instances: [
                LayoutInstance(id: instanceID, cellID: childID, name: "X1"),
            ],
            nets: [LayoutNet(id: netID, name: "vdd")]
        )
        return LayoutDocument(
            name: "fixture",
            cells: [child, top],
            topCellID: topID
        )
    }
}
