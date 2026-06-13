import Foundation
import Testing
import LayoutAutoGen
import LayoutCore
import LayoutTech

@Suite("LayoutAutoGen Public Plugin Contract")
struct LayoutAutoGenPublicPluginContractTests {

    @Test func externalPlacementEngineCanUsePublicTypes() throws {
        let instanceID = UUID()
        let engine = PublicPlacementEngine()
        let result = try engine.place(
            instances: [
                PlacementInstance(
                    id: instanceID,
                    cell: LayoutCell(name: "R"),
                    deviceType: .passive,
                    name: "R1"
                ),
            ],
            nets: [],
            tech: LayoutTechDatabase.standard()
        )

        #expect(result.placements[instanceID]?.translation == LayoutPoint(x: 10, y: 20))
        #expect(result.totalBoundingBox.size.width == 20)
        #expect(result.totalBoundingBox.size.height == 10)
    }

    @Test func externalRoutingEngineCanRunThroughRepairLoop() throws {
        let netID = UUID()
        let engine = PublicRoutingEngine()
        let verifier = PassingVerifier()
        let net = RoutingNet(
            id: netID,
            name: "out",
            pins: [
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "A",
                    absolutePosition: LayoutPoint(x: 0, y: 0),
                    layer: LayoutLayerID(name: "M1", purpose: "drawing")
                ),
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "B",
                    absolutePosition: LayoutPoint(x: 10, y: 0),
                    layer: LayoutLayerID(name: "M1", purpose: "drawing")
                ),
            ],
            isPower: false
        )

        let outcome = try DRCDrivenRoutingLoop().run(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: LayoutTechDatabase.standard(),
            engine: engine,
            verifier: verifier,
            assemble: { routing in
                let top = LayoutCell(
                    name: "TOP",
                    shapes: routing.routes.flatMap(\.shapes),
                    vias: routing.routes.flatMap(\.vias)
                )
                return LayoutDocument(name: "public-plugin", cells: [top], topCellID: top.id)
            }
        )

        #expect(outcome.routing.routes.count == 1)
        #expect(outcome.routing.routes.first?.netID == netID)
        #expect(outcome.remainingViolations.isEmpty)
    }

    @Test func externalDeviceCellGeneratorCanUsePublicCacheContract() throws {
        let generator = PublicDeviceCellGenerator()
        var cache = DeviceCellCache()
        let first = try cache.cellFor(
            deviceKindID: "custom-resistor",
            instanceName: "R1",
            parameters: ["r": 1000],
            generator: generator,
            tech: LayoutTechDatabase.standard()
        )
        let second = try cache.cellFor(
            deviceKindID: "custom-resistor",
            instanceName: "R2",
            parameters: ["r": 1000],
            generator: generator,
            tech: LayoutTechDatabase.standard()
        )

        #expect(first.id == second.id)
        #expect(first.pins.count == 2)
    }
}

private struct PublicPlacementEngine: PlacementEngine {
    func place(
        instances: [PlacementInstance],
        nets: [PlacementNet],
        tech: LayoutTechDatabase
    ) throws -> PlacementResult {
        var placements: [UUID: LayoutTransform] = [:]
        for instance in instances {
            placements[instance.id] = LayoutTransform(
                translation: LayoutPoint(x: 10, y: 20)
            )
        }
        return PlacementResult(
            placements: placements,
            powerRails: [],
            totalBoundingBox: LayoutRect(
                origin: LayoutPoint(x: 10, y: 20),
                size: LayoutSize(width: 20, height: 10)
            )
        )
    }
}

private struct PublicRoutingEngine: RoutingEngine {
    func route(
        nets: [RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase
    ) throws -> RoutingResult {
        let routes = nets.map { net in
            RoutedNet(
                netID: net.id,
                shapes: [
                    LayoutShape(
                        layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                        netID: net.id,
                        geometry: .rect(LayoutRect(
                            origin: LayoutPoint(x: 0, y: -0.1),
                            size: LayoutSize(width: 10, height: 0.2)
                        ))
                    ),
                ]
            )
        }
        return RoutingResult(routes: routes)
    }
}

private struct PublicDeviceCellGenerator: DeviceCellGenerator {
    let supportedDeviceKindIDs = ["custom-resistor"]

    func generateCell(
        deviceKindID: String,
        instanceName: String,
        parameters: [String: Double],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        LayoutCell(
            name: "\(deviceKindID)-cell",
            pins: [
                LayoutPin(
                    name: "A",
                    position: LayoutPoint(x: 0.1, y: 0.1),
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: LayoutLayerID(name: "M1", purpose: "drawing")
                ),
                LayoutPin(
                    name: "B",
                    position: LayoutPoint(x: 1.1, y: 0.1),
                    size: LayoutSize(width: 0.2, height: 0.2),
                    layer: LayoutLayerID(name: "M1", purpose: "drawing")
                ),
            ]
        )
    }
}

private struct PassingVerifier: PostRouteVerifier {
    func verify(document: LayoutDocument) throws -> [PostRouteViolation] {
        []
    }
}
