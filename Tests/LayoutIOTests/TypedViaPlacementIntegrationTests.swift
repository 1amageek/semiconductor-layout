import Foundation
import Testing
import LayoutCore
import LayoutIR
import LayoutTech
import LayoutVerify
@testable import LayoutIO

@Suite("Typed DEF via placement integration", .timeLimit(.minutes(1)))
struct TypedViaPlacementIntegrationTests {
    private let bottom = LayoutLayerID(name: "metH", purpose: "drawing")
    private let top = LayoutLayerID(name: "metV", purpose: "drawing")
    private let cut = LayoutLayerID(name: "cutHV", purpose: "cut")

    private func technology() -> LayoutTechDatabase {
        let layers = [bottom, top, cut].enumerated().map { index, id in
            LayoutLayerDefinition(id: id, displayName: id.name, gdsLayer: index + 1,
                gdsDatatype: 0, color: .init(red: 0.3, green: 0.5, blue: 0.7))
        }
        let rectangles = [
            LayoutRect(origin: .init(x: 0.1, y: -0.1), size: .init(width: 0.4, height: 0.2)),
            LayoutRect(origin: .init(x: -0.1, y: 0.1), size: .init(width: 0.2, height: 0.4)),
            LayoutRect(origin: .init(x: 0.05, y: 0.05), size: .init(width: 0.1, height: 0.1)),
        ]
        return LayoutTechDatabase(layers: layers, vias: [
            .init(id: "hv", cutLayer: cut, topLayer: top, bottomLayer: bottom,
                cutSize: .init(width: 0.1, height: 0.1), enclosure: .init(top: 0.1, bottom: 0.1),
                cutSpacing: 0, layerGeometries: zip([bottom, top, cut], rectangles).map {
                    .init(layer: $0.0, rects: [$0.1])
                })
        ], layerRules: [])
    }

    private func source(routes: String, dbu: Int = 1000, special: Bool = false) -> Data {
        let section = special ? "SPECIALNETS" : "NETS"
        return Data("""
        VERSION 5.8 ;
        DESIGN top ;
        UNITS DISTANCE MICRONS \(dbu) ;
        \(section) 1 ;
        - N \(routes) ;
        END \(section)
        END DESIGN
        """.utf8)
    }

    @Test func actualNativeStandalonePlacementsCreateNoWireAndRetainContacts() throws {
        // The four named-only placement clauses are retained from native-route-input.def.
        let origins: [(Int, Int)] = [(6500, 3300), (6500, 900), (2900, 900), (2900, 1300)]
        let routes = origins.map { "+ ROUTED metH ( \($0.0) \($0.1) ) hv" }.joined(separator: " ")
        let tech = technology()
        let document = try MaskDataFormatConverter(tech: tech).importFromData(source(routes: routes))
        let cell = try #require(document.cells.first { $0.id == document.topCellID })
        #expect(document.units.scale.databaseUnitsPerMicrometer == 1000)
        #expect(cell.shapes.isEmpty)
        #expect(cell.vias.count == 4)
        let net = try #require(cell.nets.first { $0.name == "N" })
        for (via, origin) in zip(cell.vias, origins) {
            #expect(via.viaDefinitionID == "hv")
            #expect(via.position == LayoutPoint(x: Double(origin.0) / 1000, y: Double(origin.1) / 1000))
            #expect(via.netID == net.id && via.geometryTransforms.isEmpty)
        }
        let captured = try LayoutConnectivityExtractor().captureConductors(document: document,
            tech: tech, conductiveLayers: [bottom, top])
        #expect(captured.footprints.count == 12)
        // The two metV pads at y=0.9 and y=1.3 share an edge; the lower pad also
        // overlaps the upper cut. Those physical contacts join the two placements.
        #expect(captured.contacts.count == 10 && captured.components.count == 3)
        #expect(captured.footprints.filter(\.isCut).count == 4)
        #expect(captured.footprints.allSatisfy { footprint in
            if case .via = footprint.source { return true }; return false
        })
        #expect(captured.components.map { $0.footprintIndices.count }.sorted() == [3, 3, 6])
        #expect(captured.components.allSatisfy { $0.declaredNets.count == 1 })
        let crossContacts = captured.contacts.filter {
            captured.footprints[$0.firstFootprint].sourceID != captured.footprints[$0.secondFootprint].sourceID
        }
        #expect(crossContacts.count == 2)
        for contact in crossContacts {
            #expect(Set([captured.footprints[contact.firstFootprint].sourceID,
                         captured.footprints[contact.secondFootprint].sourceID]) == Set([cell.vias[2].id, cell.vias[3].id]))
        }
        let layerPairs = crossContacts.map {
            Set([captured.footprints[$0.firstFootprint].layer, captured.footprints[$0.secondFootprint].layer])
        }
        #expect(layerPairs.contains([top]) && layerPairs.contains([top, cut]))
    }

    @Test(arguments: ["N", "S", "E", "W", "FN", "FS", "FE", "FW"])
    func allDEFOrientationsPreserveAsymmetricNativeFootprints(_ orientation: String) throws {
        let matrices: [String: (Int, Int, Int, Int)] = [
            "N": (1, 0, 0, 1), "S": (-1, 0, 0, -1),
            "E": (0, 1, -1, 0), "W": (0, -1, 1, 0),
            "FN": (-1, 0, 0, 1), "FS": (1, 0, 0, -1),
            "FE": (0, -1, -1, 0), "FW": (0, 1, 1, 0),
        ]
        let matrix = try #require(matrices[orientation])
        let tech = technology()
        let document = try MaskDataFormatConverter(tech: tech).importFromData(source(
            routes: "+ ROUTED metH ( -6500 3300 ) hv \(orientation)", dbu: 2000))
        let cell = try #require(document.cells.first { $0.id == document.topCellID })
        #expect(cell.shapes.isEmpty && cell.vias.count == 1)
        #expect(document.units.scale.databaseUnitsPerMicrometer == 2000)
        let via = try #require(cell.vias.first)
        #expect(via.position == LayoutPoint(x: -3.25, y: 1.65))
        let captured = try LayoutConnectivityExtractor().captureConductors(document: document,
            tech: tech, conductiveLayers: [bottom, top])
        #expect(captured.footprints.count == 3 && captured.contacts.count == 2 && captured.components.count == 1)
        let scale = captured.coordinateUnits.scale.databaseUnitsPerMicrometer
        for layerGeometry in tech.vias[0].layerGeometries {
            let footprint = try #require(captured.footprints.first { $0.layer == layerGeometry.layer })
            let rect = layerGeometry.rects[0]
            let corners = [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                           (rect.maxX, rect.maxY), (rect.minX, rect.maxY)]
            let xs = corners.map { (Double(matrix.0) * $0.0 + Double(matrix.1) * $0.1 - 3.25) * scale }
            let ys = corners.map { (Double(matrix.2) * $0.0 + Double(matrix.3) * $0.1 + 1.65) * scale }
            #expect(footprint.band.minX == Int32(try #require(xs.min()).rounded()))
            #expect(footprint.band.maxX == Int32(try #require(xs.max()).rounded()))
            #expect(footprint.band.minY == Int32(try #require(ys.min()).rounded()))
            #expect(footprint.band.maxY == Int32(try #require(ys.max()).rounded()))
        }
        let restored = try JSONDecoder().decode(LayoutDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.cells.first?.vias == cell.vias)
    }

    @Test func normalAndSpecialTerminalViasAreNotDuplicated() throws {
        let tech = technology()
        for special in [false, true] {
            let width = special ? " 200" : ""
            let document = try MaskDataFormatConverter(tech: tech).importFromData(source(
                routes: "+ ROUTED metH\(width) ( 0 0 ) ( 1000 0 ) hv FW", special: special))
            let cell = try #require(document.cells.first { $0.id == document.topCellID })
            #expect(cell.shapes.count == 1 && cell.vias.count == 1)
            let via = try #require(cell.vias.first)
            #expect(via.position == LayoutPoint(x: 1, y: 0))
            #expect(via.geometryTransforms == [.init(rotationDegrees: 90, mirrorY: true)])
            #expect(via.netID == cell.shapes.first?.netID)
            guard case .path(let path) = cell.shapes[0].geometry else {
                Issue.record("Expected the actual wire path"); continue
            }
            #expect(path.points == [.zero, .init(x: 1, y: 0)])
        }
    }

    private func typedLibrary(master: String = "hv", transform: IRTransform = .identity,
                              routeLayer: Int16 = 1, properties: [IRProperty] = []) -> IRLibrary {
        .init(name: "typed", databaseUnitScale: LayoutUnits.defaultUnits.scale,
            cells: [.init(name: "TOP", elements: [.via(.init(viaName: master,
                origin: .init(x: 6500, y: 3300), transform: transform,
                routeLayer: routeLayer, properties: properties))])])
    }

    @Test func unresolvedAmbiguousAndInvalidPlacementsFailBeforePublication() {
        let converter = IRLayoutConverter(), tech = technology()
        let invalid = [typedLibrary(master: "missing"), typedLibrary(master: "hv "),
            typedLibrary(transform: .init(angle: 45)), typedLibrary(transform: .init(angle: .nan)),
            typedLibrary(transform: .init(magnification: 2)), typedLibrary(routeLayer: 99),
            typedLibrary(routeLayer: 3),
            typedLibrary(properties: [.init(attribute: 0, value: "def.route.layerName=other")]),
            typedLibrary(properties: [.init(attribute: 0, value: "def.route.layerName=metV")]),
            typedLibrary(properties: [.init(attribute: 0, value: "def.route.netName=A"),
                                      .init(attribute: 0, value: "def.route.netName=B")]),
            typedLibrary(properties: [.init(attribute: 0, value: "def.route.netName= ")])]
        for library in invalid {
            #expect(throws: LayoutIOError.self) { try converter.checkedImportLibrary(library, tech: tech) }
        }
        var duplicate = tech; duplicate.vias.append(tech.vias[0])
        #expect(throws: LayoutIOError.self) { try converter.checkedImportLibrary(typedLibrary(), tech: duplicate) }
        var ambiguous = tech
        ambiguous.contacts = [.init(id: "hv", cutLayer: cut, bottomLayer: bottom, topLayer: top,
            cutSize: .init(width: 0.1, height: 0.1), enclosure: .init(top: 0.1, bottom: 0.1), cutSpacing: 0)]
        #expect(throws: LayoutIOError.self) { try converter.checkedImportLibrary(typedLibrary(), tech: ambiguous) }
    }

    @Test func explicitDEFDisplayAliasUsesItsDeclaredPhysicalLayer() throws {
        var tech = technology()
        tech.layers[0].displayName = "Metal1"
        let document = try MaskDataFormatConverter(tech: tech).importFromData(source(
            routes: "+ ROUTED metal1 ( 6500 3300 ) hv"))
        let cell = try #require(document.cells.first { $0.id == document.topCellID })
        #expect(cell.shapes.isEmpty && cell.vias.count == 1)
        #expect(cell.vias[0].viaDefinitionID == "hv")
        #expect(cell.vias[0].position == LayoutPoint(x: 6.5, y: 3.3))
        #expect(cell.vias[0].netID == cell.nets.first { $0.name == "N" }?.id)
        let captured = try LayoutConnectivityExtractor().captureConductors(document: document,
            tech: tech, conductiveLayers: [bottom, top])
        #expect(captured.footprints.count == 3 && captured.contacts.count == 2)
        #expect(captured.footprints.contains { $0.layer == bottom && !$0.isCut })
    }

    @Test func explicitContactMasterRetainsNativeCutAndLandingGeometry() throws {
        var tech = technology(); tech.vias = []
        tech.contacts = [.init(id: "hv", cutLayer: cut, bottomLayer: bottom, topLayer: top,
            cutSize: .init(width: 0.1, height: 0.1), enclosure: .init(top: 0.1, bottom: 0.1), cutSpacing: 0)]
        let document = try IRLayoutConverter().checkedImportLibrary(typedLibrary(), tech: tech)
        #expect(document.cells[0].shapes.isEmpty && document.cells[0].vias.count == 1)
        let captured = try LayoutConnectivityExtractor().captureConductors(document: document,
            tech: tech, conductiveLayers: [bottom, top])
        #expect(captured.footprints.count == 3 && captured.footprints.filter(\.isCut).count == 1)
        #expect(captured.contacts.count == 2 && captured.components.count == 1)
    }
}
