import Foundation
import LayoutCore
import LayoutTech

// MARK: - Device Classification

public enum DeviceType: String, Sendable, Codable {
    case pmos
    case nmos
    case passive
}

// MARK: - Placement Input

public struct PlacementInstance: Sendable {
    public let id: UUID
    public let cell: LayoutCell
    public let deviceType: DeviceType
    public let name: String

    public init(id: UUID, cell: LayoutCell, deviceType: DeviceType, name: String) {
        self.id = id
        self.cell = cell
        self.deviceType = deviceType
        self.name = name
    }
}

public struct PlacementNet: Sendable {
    public let name: String
    public let pinConnections: [(instanceID: UUID, pinName: String)]

    public init(name: String, pinConnections: [(instanceID: UUID, pinName: String)]) {
        self.name = name
        self.pinConnections = pinConnections
    }
}

// MARK: - Placement Output

public struct PlacementResult: Sendable {
    public var placements: [UUID: LayoutTransform]
    public var powerRails: [LayoutShape]
    public var totalBoundingBox: LayoutRect

    public init(
        placements: [UUID: LayoutTransform],
        powerRails: [LayoutShape],
        totalBoundingBox: LayoutRect
    ) {
        self.placements = placements
        self.powerRails = powerRails
        self.totalBoundingBox = totalBoundingBox
    }
}

// MARK: - Protocol

public protocol PlacementEngine: Sendable {
    func place(
        instances: [PlacementInstance],
        nets: [PlacementNet],
        tech: LayoutTechDatabase
    ) throws -> PlacementResult
}
