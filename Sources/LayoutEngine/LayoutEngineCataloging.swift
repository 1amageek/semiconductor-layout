import LayoutAutoGen
import LayoutCore
import LayoutTech

public enum PlacementEngineSelection: Sendable, Equatable {
    case greedy
    case optimized
    case registered(String)

    public var engineID: String {
        switch self {
        case .greedy:
            return "greedy"
        case .optimized:
            return "optimized"
        case .registered(let id):
            return id
        }
    }
}

public enum RoutingEngineSelection: Sendable, Equatable {
    case simple
    case steiner
    case registered(String)

    public var engineID: String {
        switch self {
        case .simple:
            return "simple"
        case .steiner:
            return "steiner"
        case .registered(let id):
            return id
        }
    }
}

public protocol PlacementEngineProviding: Sendable {
    var placementEngines: [LayoutEngineDescriptor] { get }

    func makePlacementEngine(
        for selection: PlacementEngineSelection,
        constraints: [LayoutConstraint]
    ) throws -> any PlacementEngine
}

public protocol RoutingEngineProviding: Sendable {
    var routingEngines: [LayoutEngineDescriptor] { get }

    func makeRoutingEngine(for selection: RoutingEngineSelection) throws -> any RoutingEngine
}

public protocol DeviceCellEngineProviding: Sendable {
    var deviceCellEngines: [LayoutEngineDescriptor] { get }

    func deviceCellGenerator(canonicalDeviceKindID: String) -> (any DeviceCellGenerator)?
}

public protocol PostRouteVerifierProviding: Sendable {
    var postRouteVerifiers: [LayoutEngineDescriptor] { get }

    func makePostRouteVerifier(tech: LayoutTechDatabase) throws -> any PostRouteVerifier
}

public protocol LayoutEngineCataloging:
    PlacementEngineProviding,
    RoutingEngineProviding,
    DeviceCellEngineProviding,
    PostRouteVerifierProviding
{}
