import Foundation
import Testing
import LayoutCore
import LayoutIO
import LayoutTech

/// Whole-document round-trip contracts, in one place:
///
/// - The NATIVE format (json) is the fidelity format: every model field —
///   shapes with nets, vias, labels, pins, instances with repetitions,
///   persisted constraints — must survive encode/decode exactly.
/// - GDS is the EXCHANGE format: drawn geometry (shapes, vias, labels,
///   hierarchy incl. arrays) round-trips; editor-only semantics (pins,
///   net assignments, constraints) do not exist in GDSII and are
///   asserted absent so the loss stays a documented contract, never a
///   surprise.
@Suite("Document round trip", .timeLimit(.minutes(2)))
struct DocumentRoundTripTests {

    private static let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private static let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    @Test func nativeFormatRoundTripsEveryModelField() throws {
        let document = Self.richDocument()
        let serializer = LayoutDocumentSerializer()

        let decoded = try serializer.decodeDocument(serializer.encodeDocument(document))

        #expect(decoded == document, "the native format must be lossless, field for field")
    }

    @Test func gdsRoundTripsGeometryHierarchyAndArrays() throws {
        let document = Self.richDocument()
        let tech = LayoutTechDatabase.standard()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gds-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.gds")

        let converter = GDSFormatConverter(tech: tech)
        try converter.exportDocument(document, to: url, format: .gds)
        let imported = try converter.importDocument(from: url, format: .gds)

        // Geometry equivalence through the hierarchy: flatten both and
        // compare (layer, bounding box) multisets — IDs are minted fresh
        // on import by design.
        #expect(
            Self.flattenedStamps(imported) == Self.flattenedStamps(document),
            "flattened geometry must survive the GDS round trip"
        )

        let importedTop = try #require(
            imported.cells.first { $0.name == "TOP" }
        )
        #expect(importedTop.instances.count == 2)
        let array = try #require(importedTop.instances.first { $0.repetition != nil })
        #expect(array.repetition?.columns == 3)
        #expect(array.repetition?.rows == 2)
        #expect(importedTop.vias.count == 1, "the via marker must restore the via, not plain geometry")
        #expect(importedTop.labels.map(\.text) == ["NETLABEL"])

        // Documented GDS losses: these concepts do not exist in GDSII.
        // If an exporter ever starts carrying them, this contract must be
        // revisited deliberately, not silently.
        #expect(importedTop.pins.isEmpty, "pins are editor semantics, not GDS records")
        #expect(importedTop.constraints.isEmpty, "constraints are editor semantics, not GDS records")
        #expect(
            importedTop.shapes.allSatisfy { $0.netID == nil },
            "net assignments are editor semantics, not GDS records"
        )
    }

    // MARK: - Fixture

    /// One document exercising every model feature: top cell with shapes
    /// (net-assigned rect, polygon, path), a via, a label, a pin, a
    /// constraint, one rotated child instance and one arrayed instance.
    private static func richDocument() -> LayoutDocument {
        let netA = UUID()
        let childShape = LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(origin: .zero, size: LayoutSize(width: 1, height: 0.5)))
        )
        let child = LayoutCell(name: "UNIT", shapes: [childShape])

        let rect = LayoutShape(
            layer: m1,
            netID: netA,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 0, y: 0),
                size: LayoutSize(width: 4, height: 0.4)
            ))
        )
        let polygon = LayoutShape(
            layer: m2,
            geometry: .polygon(LayoutPolygon(points: [
                LayoutPoint(x: 0, y: 2),
                LayoutPoint(x: 1.4, y: 2),
                LayoutPoint(x: 1.4, y: 3),
                LayoutPoint(x: 0.6, y: 3),
                LayoutPoint(x: 0.6, y: 2.4),
                LayoutPoint(x: 0, y: 2.4),
            ]))
        )
        let path = LayoutShape(
            layer: m2,
            netID: netA,
            geometry: .path(LayoutPath(
                points: [
                    LayoutPoint(x: 2, y: 2),
                    LayoutPoint(x: 3.5, y: 2),
                    LayoutPoint(x: 3.5, y: 3.2),
                ],
                width: 0.3,
                endCap: .truncate
            ))
        )
        let via = LayoutVia(
            viaDefinitionID: "VIA1",
            position: LayoutPoint(x: 3.0, y: 0.2),
            netID: netA
        )
        let label = LayoutLabel(text: "NETLABEL", position: LayoutPoint(x: 0.2, y: 0.2), layer: m1)
        let pin = LayoutPin(
            name: "A",
            position: LayoutPoint(x: 0.2, y: 0.2),
            size: LayoutSize(width: 0.2, height: 0.2),
            layer: m1,
            netID: netA,
            role: .signal
        )
        let rotated = LayoutInstance(
            cellID: child.id,
            name: "XR",
            transform: LayoutTransform(
                translation: LayoutPoint(x: 6, y: 1),
                rotation: .deg90
            )
        )
        let arrayed = LayoutInstance(
            cellID: child.id,
            name: "XA",
            transform: LayoutTransform(translation: LayoutPoint(x: 8, y: 0)),
            repetition: LayoutRepetition(
                columns: 3,
                rows: 2,
                columnStep: LayoutPoint(x: 2, y: 0),
                rowStep: LayoutPoint(x: 0, y: 1.5)
            )
        )
        let constraint = LayoutConstraint.matching(
            LayoutMatchingConstraint(members: [rect.id, path.id])
        )
        let top = LayoutCell(
            name: "TOP",
            shapes: [rect, polygon, path],
            vias: [via],
            labels: [label],
            pins: [pin],
            instances: [rotated, arrayed],
            nets: [LayoutNet(id: netA, name: "A")],
            constraints: [constraint]
        )
        return LayoutDocument(name: "rich", cells: [child, top], topCellID: top.id)
    }

    private struct Stamp: Hashable {
        var layer: LayoutLayerID
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    private static func flattenedStamps(_ document: LayoutDocument) -> [Stamp: Int] {
        guard let top = document.cells.first(where: { $0.name == "TOP" }) else { return [:] }
        var stamps: [Stamp: Int] = [:]
        func walk(cell: LayoutCell, transforms: [LayoutTransform], depth: Int) {
            guard depth < 8 else { return }
            for shape in cell.shapes {
                var geometry = shape.geometry
                for transform in transforms.reversed() {
                    geometry = geometry.transformed(by: transform)
                }
                let box = LayoutGeometryAnalysis.boundingBox(for: geometry)
                let stamp = Stamp(
                    layer: shape.layer,
                    x: (box.minX * 1000).rounded() / 1000,
                    y: (box.minY * 1000).rounded() / 1000,
                    width: (box.size.width * 1000).rounded() / 1000,
                    height: (box.size.height * 1000).rounded() / 1000
                )
                stamps[stamp, default: 0] += 1
            }
            for instance in cell.instances {
                guard let childCell = document.cell(withID: instance.cellID) else { continue }
                for occurrence in instance.occurrenceTransforms() {
                    walk(cell: childCell, transforms: transforms + [occurrence], depth: depth + 1)
                }
            }
        }
        walk(cell: top, transforms: [], depth: 0)
        return stamps
    }
}
