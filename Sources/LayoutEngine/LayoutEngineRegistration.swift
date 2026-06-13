import LayoutAutoGen
import LayoutCore
import LayoutTech

public struct PlacementEngineRegistration: Sendable {
    public let descriptor: LayoutEngineDescriptor
    private let makeEngineClosure: @Sendable ([LayoutConstraint]) throws -> any PlacementEngine

    public init(
        descriptor: LayoutEngineDescriptor,
        makeEngine: @escaping @Sendable ([LayoutConstraint]) throws -> any PlacementEngine
    ) {
        self.descriptor = descriptor
        self.makeEngineClosure = makeEngine
    }

    public func makeEngine(constraints: [LayoutConstraint]) throws -> any PlacementEngine {
        try makeEngineClosure(constraints)
    }
}

public struct RoutingEngineRegistration: Sendable {
    public let descriptor: LayoutEngineDescriptor
    private let makeEngineClosure: @Sendable () throws -> any RoutingEngine

    public init(
        descriptor: LayoutEngineDescriptor,
        makeEngine: @escaping @Sendable () throws -> any RoutingEngine
    ) {
        self.descriptor = descriptor
        self.makeEngineClosure = makeEngine
    }

    public func makeEngine() throws -> any RoutingEngine {
        try makeEngineClosure()
    }
}

public struct DeviceCellEngineRegistration: Sendable {
    public let descriptor: LayoutEngineDescriptor
    private let supportsClosure: @Sendable (String) -> Bool
    private let makeGeneratorClosure: @Sendable () -> any DeviceCellGenerator

    public init(
        descriptor: LayoutEngineDescriptor,
        supportedCanonicalDeviceKindIDs: Set<String>,
        makeGenerator: @escaping @Sendable () -> any DeviceCellGenerator
    ) {
        self.descriptor = descriptor
        self.supportsClosure = { canonicalDeviceKindID in
            supportedCanonicalDeviceKindIDs.contains(canonicalDeviceKindID)
        }
        self.makeGeneratorClosure = makeGenerator
    }

    public init(
        descriptor: LayoutEngineDescriptor,
        supports: @escaping @Sendable (String) -> Bool,
        makeGenerator: @escaping @Sendable () -> any DeviceCellGenerator
    ) {
        self.descriptor = descriptor
        self.supportsClosure = supports
        self.makeGeneratorClosure = makeGenerator
    }

    public func supports(canonicalDeviceKindID: String) -> Bool {
        supportsClosure(canonicalDeviceKindID)
    }

    public func makeGenerator() -> any DeviceCellGenerator {
        makeGeneratorClosure()
    }
}

public struct PostRouteVerifierRegistration: Sendable {
    public let descriptor: LayoutEngineDescriptor
    private let makeVerifierClosure: @Sendable (LayoutTechDatabase) -> any PostRouteVerifier

    public init(
        descriptor: LayoutEngineDescriptor,
        makeVerifier: @escaping @Sendable (LayoutTechDatabase) -> any PostRouteVerifier
    ) {
        self.descriptor = descriptor
        self.makeVerifierClosure = makeVerifier
    }

    public func makeVerifier(tech: LayoutTechDatabase) -> any PostRouteVerifier {
        makeVerifierClosure(tech)
    }
}
