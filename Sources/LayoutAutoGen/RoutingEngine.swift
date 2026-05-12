import Foundation
import LayoutCore
import LayoutTech

// MARK: - Routing Input

public struct RoutingPin: Sendable {
    public let instanceID: UUID
    public let pinName: String
    public let absolutePosition: LayoutPoint
    public let layer: LayoutLayerID

    public init(
        instanceID: UUID,
        pinName: String,
        absolutePosition: LayoutPoint,
        layer: LayoutLayerID
    ) {
        self.instanceID = instanceID
        self.pinName = pinName
        self.absolutePosition = absolutePosition
        self.layer = layer
    }
}

public struct RoutingNet: Sendable {
    public let id: UUID
    public let name: String
    public let pins: [RoutingPin]
    public let isPower: Bool

    public init(id: UUID, name: String, pins: [RoutingPin], isPower: Bool) {
        self.id = id
        self.name = name
        self.pins = pins
        self.isPower = isPower
    }
}

// MARK: - Routing Output

public struct RoutedNet: Sendable {
    public let netID: UUID
    public var shapes: [LayoutShape]
    public var vias: [LayoutVia]

    public init(netID: UUID, shapes: [LayoutShape] = [], vias: [LayoutVia] = []) {
        self.netID = netID
        self.shapes = shapes
        self.vias = vias
    }
}

public struct RoutingResult: Sendable {
    public var routes: [RoutedNet]
    public var unroutedNets: [String]

    public init(routes: [RoutedNet] = [], unroutedNets: [String] = []) {
        self.routes = routes
        self.unroutedNets = unroutedNets
    }
}

// MARK: - Protocol

public protocol RoutingEngine: Sendable {
    func route(
        nets: [RoutingNet],
        placements: [UUID: LayoutTransform],
        cells: [UUID: LayoutCell],
        obstructions: [LayoutShape],
        tech: LayoutTechDatabase
    ) throws -> RoutingResult
}
