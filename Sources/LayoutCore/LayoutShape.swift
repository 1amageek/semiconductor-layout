import Foundation

public struct LayoutShape: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var layer: LayoutLayerID
    public var netID: UUID?
    public var geometry: LayoutGeometry
    public var properties: [String: String]

    public init(
        id: UUID = UUID(),
        layer: LayoutLayerID,
        netID: UUID? = nil,
        geometry: LayoutGeometry,
        properties: [String: String] = [:]
    ) {
        self.id = id
        self.layer = layer
        self.netID = netID
        self.geometry = geometry
        self.properties = properties
    }
}
