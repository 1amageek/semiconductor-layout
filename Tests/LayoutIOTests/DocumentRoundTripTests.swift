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
        defer { Self.removeTemporaryDirectory(directory) }
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
        #expect(importedTop.properties.isEmpty, "cell properties are canonical state, not GDS records")
        #expect(
            importedTop.shapes.allSatisfy { $0.netID == nil },
            "net assignments are editor semantics, not GDS records"
        )
    }

    @Test func defRoundTripsPlacedComponentsAsInstances() throws {
        let document = Self.placementDocument()
        let tech = LayoutTechDatabase.standard()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("def-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Self.removeTemporaryDirectory(directory) }
        let url = directory.appendingPathComponent("placement.def")

        let converter = MaskDataFormatConverter(tech: tech)
        try converter.exportDocument(document, to: url, format: .def)
        let defText = try String(contentsOf: url, encoding: .utf8)
        #expect(defText.contains("- u1 INV + PLACED ( 1250 2500 ) FN"))

        let imported = try converter.importDocument(from: url, format: .def)
        let importedTop = try #require(imported.topCellID.flatMap { imported.cell(withID: $0) })
        #expect(imported.cells.contains { $0.name == "INV" })
        #expect(importedTop.instances.count == 1)
        let instance = try #require(importedTop.instances.first)
        #expect(instance.name == "u1")
        #expect(abs(instance.transform.translation.x - 1.25) < 0.0001)
        #expect(abs(instance.transform.translation.y - 2.5) < 0.0001)
        #expect(instance.transform.mirrorX == true)
    }

    @Test func defRoundTripsRoutedNetsAsNettedShapes() throws {
        let tech = LayoutTechDatabase.standard()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("def-routing-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Self.removeTemporaryDirectory(directory) }
        let inputURL = directory.appendingPathComponent("routing.def")
        let outputURL = directory.appendingPathComponent("routing-out.def")
        try Self.routedDEF.write(to: inputURL, atomically: true, encoding: .utf8)

        let converter = MaskDataFormatConverter(tech: tech)
        let imported = try converter.importDocument(from: inputURL, format: .def)
        let importedTop = try #require(imported.topCellID.flatMap { imported.cell(withID: $0) })

        #expect(importedTop.nets.map(\.name).sorted() == ["VDD", "clk"])
        #expect(importedTop.shapes.count == 4)
        #expect(importedTop.vias.count == 2)
        #expect(importedTop.shapes.allSatisfy { $0.netID != nil })
        #expect(importedTop.vias.allSatisfy { $0.netID != nil })
        #expect(importedTop.vias.allSatisfy { $0.viaDefinitionID == "VIA1" })
        #expect(importedTop.shapes.contains {
            $0.layer == Self.m1 && $0.properties["def.route.netName"] == "clk"
        })
        let clockRoute = try #require(importedTop.shapes.first {
            $0.layer == Self.m1 && $0.properties["def.route.netName"] == "clk"
        })
        guard case .path(let clockPath) = clockRoute.geometry else {
            Issue.record("Expected DEF clock route to import as a path")
            return
        }
        #expect(abs(clockPath.width - (tech.ruleSet(for: Self.m1)?.minWidth ?? 0)) < 0.0001)
        #expect(importedTop.shapes.contains {
            $0.layer == Self.m2
                && $0.properties["def.route.kind"] == "specialNet"
                && $0.properties["def.route.netName"] == "VDD"
        })

        try converter.exportDocument(imported, to: outputURL, format: .def)
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output.contains("NETS 1"))
        #expect(output.contains("- clk ( PIN clk ) + USE CLOCK + ROUTED metal1"))
        #expect(output.contains("( 900 200 ) VIA1"))
        #expect(output.contains("SPECIALNETS 1"))
        #expect(output.contains("- VDD ( * VDD ) + USE POWER + ROUTED metal2 300 + SHAPE STRIPE"))
        #expect(output.contains("( 1000 * ) VIA1"))
    }

    @Test func defUnknownRouteViaFailsImport() throws {
        let tech = LayoutTechDatabase.standard()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("def-unknown-via-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Self.removeTemporaryDirectory(directory) }
        let inputURL = directory.appendingPathComponent("unknown-via.def")
        try Self.unknownViaDEF.write(to: inputURL, atomically: true, encoding: .utf8)

        let converter = MaskDataFormatConverter(tech: tech)
        #expect(throws: LayoutIOError.self) {
            _ = try converter.importDocument(from: inputURL, format: .def)
        }
    }

    @Test func defViasSectionDefinesRouteViaGeometry() throws {
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("def-via-definition-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { Self.removeTemporaryDirectory(directory) }
        let inputURL = directory.appendingPathComponent("via-definition.def")
        let outputURL = directory.appendingPathComponent("via-definition-out.def")
        try Self.defWithViaDefinition.write(to: inputURL, atomically: true, encoding: .utf8)

        let converter = MaskDataFormatConverter(tech: tech)
        let importedTech = try converter.importTech(from: inputURL, format: .def)
        let defVia = try #require(importedTech.viaDefinition(for: "DEFVIA"))
        #expect(defVia.cutLayer == LayoutLayerID(name: "VIA1", purpose: "cut"))
        #expect(abs(defVia.cutSize.width - 0.05) < 0.0001)
        #expect(abs(defVia.cutSize.height - 0.05) < 0.0001)
        #expect(abs(defVia.enclosure.bottom - 0.025) < 0.0001)
        #expect(abs(defVia.enclosure.top - 0.04) < 0.0001)
        #expect(abs(defVia.cutSpacing - 0.12) < 0.0001)
        #expect(defVia.layerGeometries.count == 3)

        let imported = try converter.importDocument(from: inputURL, format: .def)
        let importedTop = try #require(imported.topCellID.flatMap { imported.cell(withID: $0) })
        let routeVia = try #require(importedTop.vias.first)
        #expect(importedTop.vias.count == 1)
        #expect(routeVia.viaDefinitionID == "DEFVIA")
        #expect(routeVia.netID != nil)
        #expect(abs(routeVia.position.x - 0.9) < 0.0001)
        #expect(abs(routeVia.position.y - 0.2) < 0.0001)
        #expect(importedTop.properties["def.viaDef.count"] == "1")

        try converter.exportDocument(imported, to: outputURL, format: .def)
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output.contains("VIAS 1"))
        #expect(output.contains("- DEFVIA + CUTSIZE 50 50 + CUTSPACING 100 120"))
        #expect(output.contains("+ RECT metal1 ( -60 -50 ) ( 60 50 )"))
        #expect(output.contains("( 900 200 ) DEFVIA"))
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
            constraints: [constraint],
            properties: ["FIXED_BBOX": "0 0 10 4"]
        )
        return LayoutDocument(name: "rich", cells: [child, top], topCellID: top.id)
    }

    private static func placementDocument() -> LayoutDocument {
        let child = LayoutCell(name: "INV")
        let instance = LayoutInstance(
            cellID: child.id,
            name: "u1",
            transform: LayoutTransform(
                translation: LayoutPoint(x: 1.25, y: 2.5),
                rotation: .deg0,
                mirrorX: true
            )
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        return LayoutDocument(name: "placement", cells: [child, top], topCellID: top.id)
    }

    private static let routedDEF = """
    VERSION 5.8 ;
    DESIGN routed ;
    UNITS DISTANCE MICRONS 1000 ;
    VIAS 1 ;
      - VIA1 + CUTSIZE 50 50 + CUTSPACING 100 100 + ENCLOSURE 10 10 10 10 + RECT metal1 ( -35 -35 ) ( 35 35 ) + RECT via1 ( -25 -25 ) ( 25 25 ) + RECT metal2 ( -35 -35 ) ( 35 35 ) ;
    END VIAS
    NETS 1 ;
      - clk ( PIN clk ) + USE CLOCK + ROUTED metal1 ( 100 200 ) ( 900 200 ) VIA1 + NEW metal2 ( 900 200 ) ( 1200 200 ) ;
    END NETS
    SPECIALNETS 1 ;
      - VDD ( * VDD ) + USE POWER + ROUTED metal2 300 + SHAPE STRIPE ( 0 1000 ) ( 1000 * ) VIA1 + NEW metal1 300 + SHAPE STRIPE ( 1000 1000 ) ( 1200 1000 ) ;
    END SPECIALNETS
    END DESIGN
    """

    private static let unknownViaDEF = """
    VERSION 5.8 ;
    DESIGN unknown_via ;
    UNITS DISTANCE MICRONS 1000 ;
    NETS 1 ;
      - clk ( PIN clk ) + USE CLOCK + ROUTED metal1 ( 100 200 ) ( 900 200 ) UNKNOWNVIA ;
    END NETS
    END DESIGN
    """

    private static let defWithViaDefinition = """
    VERSION 5.8 ;
    DESIGN via_definition ;
    UNITS DISTANCE MICRONS 1000 ;
    VIAS 1 ;
      - DEFVIA + CUTSIZE 50 50 + CUTSPACING 100 120 + ENCLOSURE 35 25 45 40 + RECT metal1 ( -60 -50 ) ( 60 50 ) + RECT via1 ( -25 -25 ) ( 25 25 ) + RECT metal2 ( -70 -65 ) ( 70 65 ) ;
    END VIAS
    NETS 1 ;
      - sig ( PIN sig ) + ROUTED metal1 ( 100 200 ) ( 900 200 ) DEFVIA ;
    END NETS
    END DESIGN
    """

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

    private static func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory \(directory.path): \(error)")
        }
    }
}
