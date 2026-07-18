import Foundation
import LayoutCore
import LayoutLVSExtraction
import LayoutTech
import Testing

@Suite("Deck-driven layout geometry extraction")
struct LayoutGeometryExtractorTests {
    @Test func extractsMOSConnectivityParametersAndPorts() throws {
        let fixture = makeFixture(includeSelector: true)
        let result = try LayoutGeometryExtractor().extract(
            document: fixture.document,
            technology: fixture.technology,
            profile: fixture.profile
        )

        #expect(result.isReady)
        #expect(result.devices.count == 1)
        #expect(result.ports.map(\.name).sorted() == ["B", "D", "G", "S"])
        let device = try #require(result.devices.first)
        #expect(device.model == "fixture_nmos")
        #expect(device.terminals.map(\.role) == ["drain", "gate", "source", "bulk"])
        #expect(device.parameters["l"] == "0.2u")
        #expect(device.parameters["w"] == "1.0u")
        #expect(Set(device.terminals.map(\.netID)).count == 4)
    }

    @Test func missingDeviceSelectorBlocksWithoutGuessing() throws {
        let fixture = makeFixture(includeSelector: false)
        let result = try LayoutGeometryExtractor().extract(
            document: fixture.document,
            technology: fixture.technology,
            profile: fixture.profile
        )

        #expect(!result.isReady)
        #expect(result.devices.isEmpty)
        #expect(result.issues.contains { $0.code == "device-selector-missing" })
    }

    @Test func conflictingNamesOnConnectedGeometryBlockExtraction() throws {
        var fixture = makeFixture(includeSelector: true)
        var top = try #require(fixture.document.cells.first)
        top.labels.append(LayoutLabel(
            text: "ALIAS",
            position: LayoutPoint(x: 0.5, y: 0.5),
            layer: LayoutLayerID(name: "diff", purpose: "drawing")
        ))
        fixture.document.cells = [top]
        let result = try LayoutGeometryExtractor().extract(
            document: fixture.document,
            technology: fixture.technology,
            profile: fixture.profile
        )

        #expect(!result.isReady)
        #expect(result.issues.contains { $0.code == "net-label-ambiguity" })
    }

    @Test func regeneratedLayoutUUIDsDoNotChangeCanonicalExtractionIR() throws {
        let firstFixture = makeFixture(includeSelector: true)
        let secondFixture = makeFixture(includeSelector: true)

        let first = try LayoutGeometryExtractor().extract(
            document: firstFixture.document,
            technology: firstFixture.technology,
            profile: firstFixture.profile
        )
        let second = try LayoutGeometryExtractor().extract(
            document: secondFixture.document,
            technology: secondFixture.technology,
            profile: secondFixture.profile
        )

        #expect(first == second)
        #expect(first.schemaVersion == 5)
        #expect(first.deckUseScope == .fixtureOnly)
        #expect(first.parameterValueConvention == .spiceSI)

        let data = try JSONEncoder().encode(first)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["deckUseScope"] as? String == "fixtureOnly")
        #expect(object["productionEligible"] == nil)
    }

    @Test func childPinsNameLocalNetsWithoutBecomingTopPorts() throws {
        var fixture = makeFixture(includeSelector: true)
        var child = try #require(fixture.document.cells.first)
        child.name = "device"
        let metal = LayoutLayerID(name: "met1", purpose: "drawing")
        child.shapes.append(LayoutShape(
            layer: metal,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 6, y: 0),
                size: LayoutSize(width: 1, height: 1)
            ))
        ))
        child.pins.append(LayoutPin(
            name: "INTERNAL_ONLY",
            position: LayoutPoint(x: 6.5, y: 0.5),
            size: LayoutSize(width: 0.1, height: 0.1),
            layer: metal
        ))
        let diffusion = LayoutLayerID(name: "diff", purpose: "drawing")
        let poly = LayoutLayerID(name: "poly", purpose: "drawing")
        let top = LayoutCell(
            name: "top",
            labels: [
                LayoutLabel(text: "D", position: LayoutPoint(x: 0.5, y: 0.5), layer: diffusion),
                LayoutLabel(text: "S", position: LayoutPoint(x: 2.5, y: 0.5), layer: diffusion),
                LayoutLabel(text: "G", position: LayoutPoint(x: 1.5, y: 1.2), layer: poly),
                LayoutLabel(text: "B", position: LayoutPoint(x: 4.5, y: 0.5), layer: metal),
            ],
            instances: [LayoutInstance(cellID: child.id, name: "XDEVICE")]
        )
        fixture.document = LayoutDocument(
            name: "hierarchical-fixture",
            cells: [top, child],
            topCellID: top.id
        )

        let result = try LayoutGeometryExtractor().extract(
            document: fixture.document,
            technology: fixture.technology,
            profile: fixture.profile
        )

        #expect(result.isReady)
        #expect(result.devices.count == 1)
        #expect(result.ports.map(\.name).sorted() == ["B", "D", "G", "S"])
        #expect(!result.ports.contains { $0.name == "INTERNAL_ONLY" })
        #expect(result.nets.contains { $0.preferredName == "INTERNAL_ONLY" } == false)
    }

    @Test func touchingDiffusionFragmentsFormOneMOSChannel() throws {
        var fixture = makeFixture(includeSelector: true)
        var top = try #require(fixture.document.cells.first)
        let diffusion = LayoutLayerID(name: "diff", purpose: "drawing")
        top.shapes.removeAll { $0.layer == diffusion }
        top.shapes.append(contentsOf: [
            LayoutShape(
                layer: diffusion,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 0.3),
                    size: LayoutSize(width: 3, height: 0.4)
                ))
            ),
            LayoutShape(
                layer: diffusion,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.2, y: 0),
                    size: LayoutSize(width: 0.6, height: 0.3)
                ))
            ),
            LayoutShape(
                layer: diffusion,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.2, y: 0.7),
                    size: LayoutSize(width: 0.6, height: 0.3)
                ))
            ),
        ])
        fixture.document.cells = [top]

        let result = try LayoutGeometryExtractor().extract(
            document: fixture.document,
            technology: fixture.technology,
            profile: fixture.profile
        )

        #expect(result.isReady)
        #expect(result.devices.count == 1)
        #expect(!result.issues.contains { $0.code == "device-terminal-unresolved" })
        let device = try #require(result.devices.first)
        #expect(device.parameters["l"] == "0.2u")
        #expect(device.parameters["w"] == "1.0u")
        let drain = try #require(device.terminals.first { $0.role == "drain" })
        let source = try #require(device.terminals.first { $0.role == "source" })
        #expect(drain.netID != source.netID)
    }

    private struct Fixture {
        var document: LayoutDocument
        let technology: LayoutTechDatabase
        let profile: LayoutExtractionProcessProfile
    }

    private func makeFixture(includeSelector: Bool) -> Fixture {
        let diffusion = LayoutLayerID(name: "diff", purpose: "drawing")
        let poly = LayoutLayerID(name: "poly", purpose: "drawing")
        let selector = LayoutLayerID(name: "nsdm", purpose: "drawing")
        let metal = LayoutLayerID(name: "met1", purpose: "drawing")
        var shapes = [
            LayoutShape(
                layer: diffusion,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 0),
                    size: LayoutSize(width: 3, height: 1)
                ))
            ),
            LayoutShape(
                layer: poly,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 1.4, y: -0.5),
                    size: LayoutSize(width: 0.2, height: 2)
                ))
            ),
            LayoutShape(
                layer: metal,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 4, y: 0),
                    size: LayoutSize(width: 1, height: 1)
                ))
            ),
        ]
        if includeSelector {
            shapes.append(LayoutShape(
                layer: selector,
                geometry: .rect(LayoutRect(
                    origin: LayoutPoint(x: 0, y: 0),
                    size: LayoutSize(width: 3, height: 1)
                ))
            ))
        }
        let cell = LayoutCell(
            name: "top",
            shapes: shapes,
            pins: [
                LayoutPin(name: "D", position: LayoutPoint(x: 0.5, y: 0.5), size: LayoutSize(width: 0.1, height: 0.1), layer: diffusion),
                LayoutPin(name: "S", position: LayoutPoint(x: 2.5, y: 0.5), size: LayoutSize(width: 0.1, height: 0.1), layer: diffusion),
                LayoutPin(name: "G", position: LayoutPoint(x: 1.5, y: 1.2), size: LayoutSize(width: 0.1, height: 0.1), layer: poly),
                LayoutPin(name: "B", position: LayoutPoint(x: 4.5, y: 0.5), size: LayoutSize(width: 0.1, height: 0.1), layer: metal),
            ]
        )
        let document = LayoutDocument(name: "fixture", cells: [cell], topCellID: cell.id)
        let layers = [diffusion, poly, selector, metal].enumerated().map { index, layer in
            LayoutLayerDefinition(
                id: layer,
                displayName: layer.name,
                gdsLayer: index + 1,
                gdsDatatype: 0,
                color: LayoutColor(red: 0, green: 0, blue: 0)
            )
        }
        let technology = LayoutTechDatabase(layers: layers, vias: [], layerRules: [])
        let profile = LayoutExtractionProcessProfile(
            processID: "fixture",
            processProfileID: "fixture.mos",
            extractionDeckDigest: "fixture-digest",
            deckUseScope: .fixtureOnly,
            conductorLayers: LayoutExtractionLayerReference(names: ["diff", "poly", "met1"]),
            connectionRules: [],
            mosRules: [
                LayoutExtractionMOSRule(
                    ruleID: "fixture-nmos",
                    model: "fixture_nmos",
                    gateLayers: LayoutExtractionLayerReference(names: ["poly"]),
                    diffusionLayers: LayoutExtractionLayerReference(names: ["diff"]),
                    selectorLayers: LayoutExtractionLayerReference(names: ["nsdm"]),
                    bulkLayers: LayoutExtractionLayerReference(names: []),
                    bulkPortCandidates: ["B"]
                ),
            ]
        )
        return Fixture(document: document, technology: technology, profile: profile)
    }
}
