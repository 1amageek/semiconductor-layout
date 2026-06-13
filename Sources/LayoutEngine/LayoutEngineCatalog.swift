import LayoutAutoGen
import LayoutCore
import LayoutTech

public struct LayoutEngineCatalog: LayoutEngineCataloging {
    private var placementRegistrations: [String: PlacementEngineRegistration]
    private var routingRegistrations: [String: RoutingEngineRegistration]
    private var deviceGeneratorRegistrations: [DeviceCellEngineRegistration]
    private var postRouteVerifierRegistration: PostRouteVerifierRegistration?

    public init(
        placementRegistrations: [PlacementEngineRegistration] = [],
        routingRegistrations: [RoutingEngineRegistration] = [],
        deviceGeneratorRegistrations: [DeviceCellEngineRegistration] = [],
        postRouteVerifierRegistration: PostRouteVerifierRegistration? = nil
    ) {
        var placementMap: [String: PlacementEngineRegistration] = [:]
        for registration in placementRegistrations {
            placementMap[registration.descriptor.id] = registration
        }
        self.placementRegistrations = placementMap

        var routingMap: [String: RoutingEngineRegistration] = [:]
        for registration in routingRegistrations {
            routingMap[registration.descriptor.id] = registration
        }
        self.routingRegistrations = routingMap
        self.deviceGeneratorRegistrations = deviceGeneratorRegistrations
        self.postRouteVerifierRegistration = postRouteVerifierRegistration
    }

    public var placementEngines: [LayoutEngineDescriptor] {
        placementRegistrations.values.map(\.descriptor).sortedByID()
    }

    public var routingEngines: [LayoutEngineDescriptor] {
        routingRegistrations.values.map(\.descriptor).sortedByID()
    }

    public var deviceCellEngines: [LayoutEngineDescriptor] {
        deviceGeneratorRegistrations.map(\.descriptor).sortedByID()
    }

    public var postRouteVerifiers: [LayoutEngineDescriptor] {
        guard let postRouteVerifierRegistration else { return [] }
        return [postRouteVerifierRegistration.descriptor]
    }

    public static func standard() -> LayoutEngineCatalog {
        var registry = LayoutEngineCatalog()
        registry.register(Self.greedyPlacementRegistration())
        registry.register(Self.optimizedPlacementRegistration())
        registry.register(Self.simpleRoutingRegistration())
        registry.register(Self.steinerRoutingRegistration())
        registry.register(Self.mosfetGeneratorRegistration())
        registry.register(Self.resistorGeneratorRegistration())
        registry.register(Self.capacitorGeneratorRegistration())
        return registry
    }

    public mutating func register(_ registration: PlacementEngineRegistration) {
        placementRegistrations[registration.descriptor.id] = registration
    }

    public mutating func register(_ registration: RoutingEngineRegistration) {
        routingRegistrations[registration.descriptor.id] = registration
    }

    public mutating func register(_ registration: DeviceCellEngineRegistration) {
        deviceGeneratorRegistrations.append(registration)
    }

    public mutating func register(_ registration: PostRouteVerifierRegistration) {
        postRouteVerifierRegistration = registration
    }

    public func registering(_ registration: PlacementEngineRegistration) -> LayoutEngineCatalog {
        var registry = self
        registry.register(registration)
        return registry
    }

    public func registering(_ registration: RoutingEngineRegistration) -> LayoutEngineCatalog {
        var registry = self
        registry.register(registration)
        return registry
    }

    public func registering(_ registration: DeviceCellEngineRegistration) -> LayoutEngineCatalog {
        var registry = self
        registry.register(registration)
        return registry
    }

    public func registering(_ registration: PostRouteVerifierRegistration) -> LayoutEngineCatalog {
        var registry = self
        registry.register(registration)
        return registry
    }

    public func makePlacementEngine(
        for selection: PlacementEngineSelection,
        constraints: [LayoutConstraint]
    ) throws -> any PlacementEngine {
        let id = selection.engineID
        guard let registration = placementRegistrations[id] else {
            throw LayoutEngineCatalogError.unknownPlacementEngine(
                id: id,
                availableIDs: Array(placementRegistrations.keys)
            )
        }
        return try registration.makeEngine(constraints: constraints)
    }

    public func makeRoutingEngine(for selection: RoutingEngineSelection) throws -> any RoutingEngine {
        let id = selection.engineID
        guard let registration = routingRegistrations[id] else {
            throw LayoutEngineCatalogError.unknownRoutingEngine(
                id: id,
                availableIDs: Array(routingRegistrations.keys)
            )
        }
        return try registration.makeEngine()
    }

    public func deviceCellGenerator(canonicalDeviceKindID: String) -> (any DeviceCellGenerator)? {
        for registration in deviceGeneratorRegistrations.reversed()
        where registration.supports(canonicalDeviceKindID: canonicalDeviceKindID) {
            return registration.makeGenerator()
        }
        return nil
    }

    public func makePostRouteVerifier(tech: LayoutTechDatabase) throws -> any PostRouteVerifier {
        guard let postRouteVerifierRegistration else {
            throw LayoutEngineCatalogError.missingPostRouteVerifier
        }
        return postRouteVerifierRegistration.makeVerifier(tech: tech)
    }
}

private extension LayoutEngineCatalog {
    static func greedyPlacementRegistration() -> PlacementEngineRegistration {
        PlacementEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "greedy",
                name: "Greedy Row Placement",
                version: "1.0",
                role: .placement,
                summary: "Classifies devices into rows and places each row by local connectivity.",
                isDeterministic: true,
                source: "built-in"
            ),
            makeEngine: { _ in RowBasedPlacementEngine() }
        )
    }

    static func optimizedPlacementRegistration() -> PlacementEngineRegistration {
        PlacementEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "optimized",
                name: "Simulated Annealing Placement",
                version: "1.0",
                role: .placement,
                summary: "Uses greedy row placement as a warm start and optimizes placement cost.",
                isDeterministic: true,
                source: "built-in"
            ),
            makeEngine: { constraints in
                SAPlacementEngine(
                    configuration: .init(
                        initialTemperature: 1000,
                        coolingRate: 0.97,
                        minTemperature: 0.1
                    ),
                    constraints: constraints
                )
            }
        )
    }

    static func simpleRoutingRegistration() -> RoutingEngineRegistration {
        RoutingEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "simple",
                name: "Simple Manhattan Routing",
                version: "1.0",
                role: .routing,
                summary: "Routes Manhattan MST edges with M1, M2, and VIA1 transitions.",
                isDeterministic: true,
                source: "built-in"
            ),
            makeEngine: { SimpleRoutingEngine() }
        )
    }

    static func steinerRoutingRegistration() -> RoutingEngineRegistration {
        RoutingEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "steiner",
                name: "Steiner Congestion Routing",
                version: "1.0",
                role: .routing,
                summary: "Uses rectilinear Steiner trees with congestion-aware rip-up and reroute.",
                isDeterministic: true,
                source: "built-in"
            ),
            makeEngine: { SteinerRoutingEngine() }
        )
    }

    static func mosfetGeneratorRegistration() -> DeviceCellEngineRegistration {
        DeviceCellEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "mosfet-cell-generator",
                name: "MOSFET Cell Generator",
                version: "1.0",
                role: .deviceCellGeneration,
                summary: "Generates NMOS and PMOS layout cells.",
                isDeterministic: true,
                source: "built-in"
            ),
            supportedCanonicalDeviceKindIDs: ["nmos", "pmos"],
            makeGenerator: { MOSFETCellGenerator() }
        )
    }

    static func resistorGeneratorRegistration() -> DeviceCellEngineRegistration {
        DeviceCellEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "resistor-cell-generator",
                name: "Resistor Cell Generator",
                version: "1.0",
                role: .deviceCellGeneration,
                summary: "Generates resistor layout cells.",
                isDeterministic: true,
                source: "built-in"
            ),
            supportedCanonicalDeviceKindIDs: ["resistor"],
            makeGenerator: { ResistorCellGenerator() }
        )
    }

    static func capacitorGeneratorRegistration() -> DeviceCellEngineRegistration {
        DeviceCellEngineRegistration(
            descriptor: LayoutEngineDescriptor(
                id: "capacitor-cell-generator",
                name: "Capacitor Cell Generator",
                version: "1.0",
                role: .deviceCellGeneration,
                summary: "Generates capacitor layout cells.",
                isDeterministic: true,
                source: "built-in"
            ),
            supportedCanonicalDeviceKindIDs: ["capacitor"],
            makeGenerator: { CapacitorCellGenerator() }
        )
    }

}

private extension Array where Element == LayoutEngineDescriptor {
    func sortedByID() -> [LayoutEngineDescriptor] {
        sorted { $0.id < $1.id }
    }
}
