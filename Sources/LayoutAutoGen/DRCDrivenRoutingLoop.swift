import Foundation
import LayoutCore
import LayoutTech

/// Routes, verifies, and repairs: runs a routing engine, hands the
/// assembled document to a post-route verifier, attributes violations to
/// routed nets through shape/via/net IDs, then rips up and reroutes the
/// implicated nets with the kept routes registered as obstructions.
///
/// The loop is honest about what it cannot fix: violations that survive
/// the iteration budget — or that implicate no routable net, such as
/// cell-internal geometry — are returned in `remainingViolations` instead
/// of being dropped. A victim whose reroute fails keeps its original route
/// so repair never makes connectivity worse than the starting point.
public struct DRCDrivenRoutingLoop {

    public struct Configuration: Sendable {
        /// Maximum number of rip-up-and-reroute rounds.
        public var maxRepairIterations: Int
        /// Maximum times a single net may be ripped up across rounds.
        public var maxRipUpsPerNet: Int

        public init(maxRepairIterations: Int = 3, maxRipUpsPerNet: Int = 2) {
            self.maxRepairIterations = maxRepairIterations
            self.maxRipUpsPerNet = maxRipUpsPerNet
        }
    }

    public struct Outcome {
        public var routing: RoutingResult
        public var document: LayoutDocument
        /// Rip-up-and-reroute rounds actually executed.
        public var repairIterations: Int
        /// Times each net was ripped up, by net ID. Nets pinned at the
        /// per-net cap after a failed reroute also appear here.
        public var ripUpCounts: [UUID: Int]
        /// Violations still present in the final document.
        public var remainingViolations: [PostRouteViolation]
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Runs the route → assemble → verify → repair cycle.
    ///
    /// `assemble` must preserve shape and via identity (IDs) from the
    /// routing result into the document, or violation attribution cannot
    /// find the owning nets.
    public func run(
        nets: [RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase,
        engine: any RoutingEngine,
        verifier: any PostRouteVerifier,
        assemble: (RoutingResult) throws -> LayoutDocument
    ) throws -> Outcome {
        let netsByID = Dictionary(uniqueKeysWithValues: nets.map { ($0.id, $0) })

        var routing = try engine.route(
            nets: nets,
            placements: placements,
            cells: cells,
            obstructions: obstructions,
            tech: tech
        )
        var ripUpCounts: [UUID: Int] = [:]
        var iterations = 0

        while true {
            let document = try assemble(routing)
            let violations = try verifier.verify(document: document)

            if violations.isEmpty || iterations >= configuration.maxRepairIterations {
                return Outcome(
                    routing: routing,
                    document: document,
                    repairIterations: iterations,
                    ripUpCounts: ripUpCounts,
                    remainingViolations: violations
                )
            }

            let victims = victimNetIDs(
                for: violations,
                routing: routing,
                netsByID: netsByID,
                ripUpCounts: ripUpCounts
            )
            guard !victims.isEmpty else {
                // Nothing routable is implicated (or every implicated net
                // exhausted its rip-up budget): rerouting cannot help.
                return Outcome(
                    routing: routing,
                    document: document,
                    repairIterations: iterations,
                    ripUpCounts: ripUpCounts,
                    remainingViolations: violations
                )
            }

            iterations += 1
            for netID in victims {
                ripUpCounts[netID, default: 0] += 1
            }

            routing = try repair(
                routing: routing,
                victims: victims,
                netsByID: netsByID,
                placements: placements,
                cells: cells,
                obstructions: obstructions,
                tech: tech,
                engine: engine,
                ripUpCounts: &ripUpCounts
            )
        }
    }

    // MARK: - Violation Attribution

    /// Nets implicated by the violations that are still allowed to be
    /// ripped up: owners of referenced shapes/vias plus directly referenced
    /// nets, restricted to nets the caller asked to route.
    private func victimNetIDs(
        for violations: [PostRouteViolation],
        routing: RoutingResult,
        netsByID: [UUID: RoutingNet],
        ripUpCounts: [UUID: Int]
    ) -> Set<UUID> {
        var shapeOwners: [UUID: UUID] = [:]
        var viaOwners: [UUID: UUID] = [:]
        for route in routing.routes {
            for shape in route.shapes {
                shapeOwners[shape.id] = route.netID
            }
            for via in route.vias {
                viaOwners[via.id] = route.netID
            }
        }

        var implicated: Set<UUID> = []
        for violation in violations {
            for shapeID in violation.shapeIDs {
                if let owner = shapeOwners[shapeID] {
                    implicated.insert(owner)
                }
            }
            for viaID in violation.viaIDs {
                if let owner = viaOwners[viaID] {
                    implicated.insert(owner)
                }
            }
            for netID in violation.netIDs where netsByID[netID] != nil {
                implicated.insert(netID)
            }
        }

        return implicated.filter { netID in
            netsByID[netID] != nil
                && ripUpCounts[netID, default: 0] < configuration.maxRipUpsPerNet
        }
    }

    // MARK: - Rip-Up and Reroute

    /// Removes the victims' routes, reroutes them against the kept routes
    /// as obstructions, and merges the results. A victim whose reroute
    /// fails gets its original route back and its rip-up count pinned to
    /// the cap so it is not victimized again.
    private func repair(
        routing: RoutingResult,
        victims: Set<UUID>,
        netsByID: [UUID: RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase,
        engine: any RoutingEngine,
        ripUpCounts: inout [UUID: Int]
    ) throws -> RoutingResult {
        var keptRoutes: [RoutedNet] = []
        var rippedRoutes: [UUID: RoutedNet] = [:]
        for route in routing.routes {
            if victims.contains(route.netID) {
                rippedRoutes[route.netID] = route
            } else {
                keptRoutes.append(route)
            }
        }

        // Kept routes become hard obstructions; their shapes carry net IDs,
        // so the engine's same-net exemptions still apply.
        var rerouteObstructions = obstructions
        for route in keptRoutes {
            rerouteObstructions.append(contentsOf: route.shapes)
        }

        let victimNets = victims
            .compactMap { netsByID[$0] }
            .sorted { $0.name < $1.name }
        let rerouted = try engine.route(
            nets: victimNets,
            placements: placements,
            cells: cells,
            obstructions: rerouteObstructions,
            tech: tech
        )

        var unroutedNames = Set(routing.unroutedNets)
        let reroutedFailures = Set(rerouted.unroutedNets)
        let reroutedByNetID = Dictionary(
            uniqueKeysWithValues: rerouted.routes.map { ($0.netID, $0) }
        )

        var mergedRoutes = keptRoutes
        for net in victimNets {
            let newRoute = reroutedByNetID[net.id]
            if let newRoute, !reroutedFailures.contains(net.name) {
                mergedRoutes.append(newRoute)
                unroutedNames.remove(net.name)
                continue
            }
            // Reroute failed: restore the original route when there is
            // one, otherwise keep the partial reroute, and pin the rip-up
            // count so this net is not victimized again.
            ripUpCounts[net.id] = configuration.maxRipUpsPerNet
            if let original = rippedRoutes[net.id] {
                mergedRoutes.append(original)
            } else if let partial = newRoute {
                mergedRoutes.append(partial)
                unroutedNames.insert(net.name)
            } else {
                unroutedNames.insert(net.name)
            }
        }

        return RoutingResult(
            routes: mergedRoutes,
            unroutedNets: unroutedNames.sorted()
        )
    }
}
