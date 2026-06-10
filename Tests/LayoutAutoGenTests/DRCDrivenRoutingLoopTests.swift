import Foundation
import Synchronization
import Testing
@testable import LayoutAutoGen
import LayoutCore
import LayoutTech
import LayoutVerify

/// Contract: the repair loop fixes what it can attribute to routed nets,
/// never exceeds its rip-up budgets, restores routes whose reroute failed,
/// and reports every violation it could not eliminate.
@Suite("DRC-Driven Routing Loop", .timeLimit(.minutes(5)))
struct DRCDrivenRoutingLoopTests {

    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    // MARK: - Fakes

    /// Verifier scripted by a closure receiving the call index, so tests
    /// can reference real routed shape IDs from the assembled document.
    private final class ClosureVerifier: PostRouteVerifier, Sendable {
        private let calls = Mutex(0)
        private let body: @Sendable (LayoutDocument, Int) -> [PostRouteViolation]

        init(_ body: @escaping @Sendable (LayoutDocument, Int) -> [PostRouteViolation]) {
            self.body = body
        }

        func verify(document: LayoutDocument) throws -> [PostRouteViolation] {
            let index = calls.withLock { count in
                let current = count
                count += 1
                return current
            }
            return body(document, index)
        }
    }

    /// Engine that routes normally on the first call and reports every net
    /// unrouted afterwards, to exercise the restore-on-failed-reroute path.
    private final class FailingRerouteEngine: RoutingEngine, Sendable {
        private let calls = Mutex(0)
        private let inner = SimpleRoutingEngine()

        func route(
            nets: [RoutingNet],
            placements: [UUID: LayoutTransform],
            cells: [UUID: LayoutCell],
            obstructions: [LayoutShape],
            tech: LayoutTechDatabase
        ) throws -> RoutingResult {
            let index = calls.withLock { count in
                let current = count
                count += 1
                return current
            }
            if index == 0 {
                return try inner.route(
                    nets: nets,
                    placements: placements,
                    cells: cells,
                    obstructions: obstructions,
                    tech: tech
                )
            }
            return RoutingResult(routes: [], unroutedNets: nets.map(\.name))
        }
    }

    // MARK: - Fixtures

    private func makeNet(name: String, points: [LayoutPoint]) -> RoutingNet {
        RoutingNet(
            id: UUID(),
            name: name,
            pins: points.map { point in
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "P",
                    absolutePosition: point,
                    layer: m1
                )
            },
            isPower: false
        )
    }

    /// Flattens routes (preserving shape and via identity) plus any extra
    /// shapes into a single-cell document, mirroring the production
    /// assembly contract the loop depends on.
    private func assemble(
        routing: RoutingResult,
        extraShapes: [LayoutShape] = []
    ) -> LayoutDocument {
        var shapes = extraShapes
        var vias: [LayoutVia] = []
        for route in routing.routes {
            shapes.append(contentsOf: route.shapes)
            vias.append(contentsOf: route.vias)
        }
        let top = LayoutCell(name: "TOP", shapes: shapes, vias: vias)
        return LayoutDocument(name: "test", cells: [top], topCellID: top.id)
    }

    private func runLoop(
        nets: [RoutingNet],
        engine: any RoutingEngine = SimpleRoutingEngine(),
        verifier: any PostRouteVerifier,
        configuration: DRCDrivenRoutingLoop.Configuration = .init(),
        extraShapes: [LayoutShape] = []
    ) throws -> DRCDrivenRoutingLoop.Outcome {
        try DRCDrivenRoutingLoop(configuration: configuration).run(
            nets: nets,
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: LayoutTechDatabase.standard(),
            engine: engine,
            verifier: verifier,
            assemble: { routing in
                self.assemble(routing: routing, extraShapes: extraShapes)
            }
        )
    }

    private func firstShapeID(of netID: UUID, in document: LayoutDocument) -> UUID? {
        document.cells
            .first { $0.name == "TOP" }?
            .shapes
            .first { $0.netID == netID }?
            .id
    }

    // MARK: - Loop Mechanics

    @Test func cleanFirstPassRunsZeroRepairs() throws {
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let verifier = ClosureVerifier { _, _ in [] }

        let outcome = try runLoop(nets: [net], verifier: verifier)

        #expect(outcome.repairIterations == 0)
        #expect(outcome.remainingViolations.isEmpty)
        #expect(outcome.ripUpCounts.isEmpty)
        #expect(outcome.routing.unroutedNets.isEmpty)
        #expect(outcome.routing.routes.count == 1)
    }

    @Test func violationAttributedByShapeIDRipsUpAndResolves() throws {
        let netA = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let netB = makeNet(name: "b", points: [LayoutPoint(x: 0, y: 3), LayoutPoint(x: 4, y: 3)])
        let netAID = netA.id
        let verifier = ClosureVerifier { document, index in
            guard index == 0 else { return [] }
            guard let shapeID = document.cells
                .flatMap(\.shapes)
                .first(where: { $0.netID == netAID })?.id
            else { return [] }
            return [PostRouteViolation(message: "synthetic spacing", shapeIDs: [shapeID])]
        }

        let outcome = try runLoop(nets: [netA, netB], verifier: verifier)

        #expect(outcome.repairIterations == 1)
        #expect(outcome.ripUpCounts == [netAID: 1])
        #expect(outcome.remainingViolations.isEmpty)
        // The victim is rerouted, not dropped.
        let routeA = outcome.routing.routes.first { $0.netID == netAID }
        #expect(routeA?.shapes.isEmpty == false)
        #expect(outcome.routing.unroutedNets.isEmpty)
    }

    @Test func violationAttributedByViaIDRipsUpTheOwningNet() throws {
        // Same-X pins force an M1-VIA-M2-VIA-M1 path, so the route owns vias.
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 0, y: 4)])
        let netID = net.id
        let verifier = ClosureVerifier { document, index in
            guard index == 0 else { return [] }
            guard let viaID = document.cells
                .flatMap(\.vias)
                .first(where: { $0.netID == netID })?.id
            else { return [] }
            return [PostRouteViolation(message: "synthetic enclosure", viaIDs: [viaID])]
        }

        let outcome = try runLoop(nets: [net], verifier: verifier)

        #expect(outcome.repairIterations == 1)
        #expect(outcome.ripUpCounts == [netID: 1])
        #expect(outcome.remainingViolations.isEmpty)
    }

    @Test func violationAttributedByNetIDRipsUpTheNet() throws {
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let netID = net.id
        let verifier = ClosureVerifier { _, index in
            index == 0 ? [PostRouteViolation(message: "synthetic open", netIDs: [netID])] : []
        }

        let outcome = try runLoop(nets: [net], verifier: verifier)

        #expect(outcome.repairIterations == 1)
        #expect(outcome.ripUpCounts == [netID: 1])
        #expect(outcome.remainingViolations.isEmpty)
    }

    @Test func persistentViolationStopsAtPerNetRipUpBudget() throws {
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let netID = net.id
        let verifier = ClosureVerifier { _, _ in
            [PostRouteViolation(message: "persistent", netIDs: [netID])]
        }
        let configuration = DRCDrivenRoutingLoop.Configuration(
            maxRepairIterations: 5,
            maxRipUpsPerNet: 2
        )

        let outcome = try runLoop(nets: [net], verifier: verifier, configuration: configuration)

        // Two rip-ups exhaust the per-net budget; the third round finds no
        // eligible victim and returns the violation honestly.
        #expect(outcome.repairIterations == 2)
        #expect(outcome.ripUpCounts == [netID: 2])
        #expect(outcome.remainingViolations.count == 1)
        #expect(outcome.routing.routes.count == 1)
    }

    @Test func persistentViolationStopsAtIterationBudget() throws {
        let netA = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let netB = makeNet(name: "b", points: [LayoutPoint(x: 0, y: 3), LayoutPoint(x: 4, y: 3)])
        let ids = [netA.id, netB.id]
        let rounds = Mutex(0)
        let verifier = ClosureVerifier { _, _ in
            // Alternate victims so the per-net budget never binds first.
            let round = rounds.withLock { value in
                let current = value
                value += 1
                return current
            }
            return [PostRouteViolation(message: "persistent", netIDs: [ids[round % 2]])]
        }
        let configuration = DRCDrivenRoutingLoop.Configuration(
            maxRepairIterations: 2,
            maxRipUpsPerNet: 10
        )

        let outcome = try runLoop(nets: [netA, netB], verifier: verifier, configuration: configuration)

        #expect(outcome.repairIterations == 2)
        #expect(outcome.remainingViolations.count == 1)
    }

    @Test func unattributableViolationReturnsImmediately() throws {
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let verifier = ClosureVerifier { _, _ in
            [PostRouteViolation(
                message: "cell-internal geometry",
                shapeIDs: [UUID()],
                netIDs: [UUID()]
            )]
        }

        let outcome = try runLoop(nets: [net], verifier: verifier)

        #expect(outcome.repairIterations == 0)
        #expect(outcome.ripUpCounts.isEmpty)
        #expect(outcome.remainingViolations.count == 1)
    }

    @Test func failedRerouteRestoresTheOriginalRoute() throws {
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 4, y: 0)])
        let netID = net.id
        let verifier = ClosureVerifier { _, _ in
            [PostRouteViolation(message: "persistent", netIDs: [netID])]
        }
        let engine = FailingRerouteEngine()

        let outcome = try runLoop(nets: [net], engine: engine, verifier: verifier)

        // One repair round runs, the reroute fails, the original route
        // comes back, and the net is pinned so the loop terminates.
        #expect(outcome.repairIterations == 1)
        #expect(outcome.ripUpCounts == [netID: 2])
        #expect(outcome.remainingViolations.count == 1)
        let route = outcome.routing.routes.first { $0.netID == netID }
        #expect(route?.shapes.isEmpty == false)
        #expect(outcome.routing.unroutedNets.isEmpty)
    }

    // MARK: - Real DRC Integration

    /// Bridges the real DRC service into the loop, as production does.
    private struct DRCVerifier: PostRouteVerifier {
        let tech: LayoutTechDatabase

        func verify(document: LayoutDocument) throws -> [PostRouteViolation] {
            let result = LayoutDRCService().run(document: document, tech: tech)
            return result.violations
                .filter { $0.severity == .error }
                .map { violation in
                    PostRouteViolation(
                        message: violation.message,
                        layer: violation.layer,
                        region: violation.region,
                        shapeIDs: violation.shapeIDs,
                        viaIDs: violation.viaIDs,
                        netIDs: violation.netIDs
                    )
                }
        }
    }

    @Test func realDRCPassesCleanRoutingWithoutRepair() throws {
        let netA = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 6, y: 0)])
        let netB = makeNet(name: "b", points: [LayoutPoint(x: 0, y: 4), LayoutPoint(x: 6, y: 4)])
        let verifier = DRCVerifier(tech: LayoutTechDatabase.standard())

        let outcome = try runLoop(nets: [netA, netB], verifier: verifier)

        #expect(outcome.repairIterations == 0)
        #expect(
            outcome.remainingViolations.isEmpty,
            "clean routing flagged: \(outcome.remainingViolations.map(\.message))"
        )
    }

    @Test func realDRCViolationIsAttributedAndReportedWhenUnfixable() throws {
        // A foreign blocker the router never sees overlaps the pin's M1
        // landing, which every reroute must revisit: the loop must
        // attribute the short to the net, exhaust the budget, and report
        // it — not drop it.
        let net = makeNet(name: "a", points: [LayoutPoint(x: 0, y: 0), LayoutPoint(x: 6, y: 0)])
        let netID = net.id
        let blocker = LayoutShape(
            layer: m1,
            netID: UUID(),
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: -0.2, y: -0.2),
                size: LayoutSize(width: 0.4, height: 0.4)
            ))
        )
        let verifier = DRCVerifier(tech: LayoutTechDatabase.standard())

        let outcome = try runLoop(
            nets: [net],
            verifier: verifier,
            extraShapes: [blocker]
        )

        #expect(!outcome.remainingViolations.isEmpty)
        #expect(outcome.ripUpCounts[netID, default: 0] > 0, "violation was not attributed to the routed net")
        // Connectivity is never sacrificed to the repair attempt.
        let route = outcome.routing.routes.first { $0.netID == netID }
        #expect(route?.shapes.isEmpty == false)
    }
}
