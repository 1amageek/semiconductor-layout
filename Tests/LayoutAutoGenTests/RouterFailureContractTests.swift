import Foundation
import Testing
@testable import LayoutAutoGen
import LayoutCore
import LayoutTech

@Suite("Router Failure Contract")
struct RouterFailureContractTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    @Test func channelRouterDoesNotCommitCollidingFallbackWhenMazeFails() throws {
        let tree = SteinerTree.construct(pins: [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 2, y: 2),
        ])
        let tech = LayoutTechDatabase.standard()
        var congestion = try CongestionGrid(
            boundingBox: LayoutRect(
                origin: LayoutPoint(x: -1, y: -1),
                size: LayoutSize(width: 4, height: 4)
            ),
            tech: tech
        )
        var obstructions = ObstructionMap()
        let blockingRect = LayoutRect(
            origin: LayoutPoint(x: -2, y: -2),
            size: LayoutSize(width: 6, height: 6)
        )
        obstructions.register(rect: blockingRect, layer: m1)
        obstructions.register(rect: blockingRect, layer: m2)

        #expect(throws: ChannelRouter.RoutingFailure.unroutableEdge) {
            _ = try ChannelRouter().routeCongestionAware(
                tree: tree,
                tech: tech,
                congestion: &congestion,
                obstMap: obstructions,
                grid: tech.grid
            )
        }
    }

    @Test func steinerRoutingReportsUnroutedNetWithoutDirtyRoute() throws {
        let tech = LayoutTechDatabase.standard()
        let netID = UUID()
        let net = RoutingNet(
            id: netID,
            name: "sig",
            pins: [
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "A",
                    absolutePosition: LayoutPoint(x: 0, y: 0),
                    layer: m1
                ),
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "Y",
                    absolutePosition: LayoutPoint(x: 2, y: 2),
                    layer: m1
                ),
            ],
            isPower: false
        )
        let blockingRect = LayoutRect(
            origin: LayoutPoint(x: -2, y: -2),
            size: LayoutSize(width: 6, height: 6)
        )
        let result = try SteinerRoutingEngine(configuration: .init(enableRipUpReroute: false)).route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [
                LayoutShape(layer: m1, geometry: .rect(blockingRect)),
                LayoutShape(layer: m2, geometry: .rect(blockingRect)),
            ],
            tech: tech
        )

        #expect(result.unroutedNets == ["sig"])
        #expect(result.routes.isEmpty)
    }

    @Test func simpleRoutingKeepsSinglePinSignalRoutedWithoutViaDefinition() throws {
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        let netID = UUID()
        let net = signalNet(id: netID, name: "sig", positions: [LayoutPoint(x: 0, y: 0)])

        let result = try SimpleRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: tech
        )

        #expect(result.unroutedNets.isEmpty)
        let routed = try #require(result.routes.first)
        #expect(routed.netID == netID)
        #expect(routed.shapes.isEmpty)
        #expect(routed.vias.isEmpty)
    }

    @Test func steinerRoutingKeepsSinglePinSignalRoutedWithoutViaDefinition() throws {
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        let netID = UUID()
        let net = signalNet(id: netID, name: "sig", positions: [LayoutPoint(x: 0, y: 0)])

        let result = try SteinerRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: tech
        )

        #expect(result.unroutedNets.isEmpty)
        let routed = try #require(result.routes.first)
        #expect(routed.netID == netID)
        #expect(routed.shapes.isEmpty)
        #expect(routed.vias.isEmpty)
    }

    @Test func simpleRoutingReportsPowerNetUnroutedWithoutViaDefinition() throws {
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        let net = powerNet(id: UUID(), name: "vdd", positions: [LayoutPoint(x: 0, y: 0)])

        let result = try SimpleRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [powerRail(y: 1.0)],
            tech: tech
        )

        #expect(result.routes.isEmpty)
        #expect(result.unroutedNets == ["vdd"])
    }

    @Test func steinerRoutingReportsPowerNetUnroutedWithoutViaDefinition() throws {
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        let net = powerNet(id: UUID(), name: "vdd", positions: [LayoutPoint(x: 0, y: 0)])

        let result = try SteinerRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [powerRail(y: 1.0)],
            tech: tech
        )

        #expect(result.routes.isEmpty)
        #expect(result.unroutedNets == ["vdd"])
    }

    @Test func simpleRoutingReportsZeroPinNetAsUnrouted() throws {
        let net = RoutingNet(id: UUID(), name: "floating", pins: [], isPower: false)

        let result = try SimpleRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: LayoutTechDatabase.standard()
        )

        #expect(result.routes.isEmpty)
        #expect(result.unroutedNets == ["floating"])
    }

    @Test func steinerRoutingReportsZeroPinPowerNetAsUnrouted() throws {
        let net = RoutingNet(id: UUID(), name: "vdd", pins: [], isPower: true)

        let result = try SteinerRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [powerRail(y: 1.0)],
            tech: LayoutTechDatabase.standard()
        )

        #expect(result.routes.isEmpty)
        #expect(result.unroutedNets == ["vdd"])
    }

    private func signalNet(id: UUID, name: String, positions: [LayoutPoint]) -> RoutingNet {
        RoutingNet(
            id: id,
            name: name,
            pins: pins(positions),
            isPower: false
        )
    }

    private func powerNet(id: UUID, name: String, positions: [LayoutPoint]) -> RoutingNet {
        RoutingNet(
            id: id,
            name: name,
            pins: pins(positions),
            isPower: true
        )
    }

    private func pins(_ positions: [LayoutPoint]) -> [RoutingPin] {
        positions.map { position in
            RoutingPin(
                instanceID: UUID(),
                pinName: "P",
                absolutePosition: position,
                layer: m1
            )
        }
    }

    private func powerRail(y: Double) -> LayoutShape {
        LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -1.0, y: y - 0.1),
                size: LayoutSize(width: 2.0, height: 0.2)
            ))
        )
    }
}
