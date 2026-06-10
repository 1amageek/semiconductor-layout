import Foundation
import Testing
@testable import LayoutAutoGen
import LayoutCore
import LayoutTech

@Suite("Router Failure Contract")
struct RouterFailureContractTests {
    @Test func channelRouterDoesNotCommitCollidingFallbackWhenMazeFails() throws {
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
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
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
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
}
