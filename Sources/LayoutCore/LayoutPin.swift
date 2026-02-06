import Foundation

public struct LayoutPin: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var position: LayoutPoint
    public var size: LayoutSize
    public var layer: LayoutLayerID
    public var netID: UUID?
    public var role: LayoutPinRole

    public init(
        id: UUID = UUID(),
        name: String,
        position: LayoutPoint,
        size: LayoutSize,
        layer: LayoutLayerID,
        netID: UUID? = nil,
        role: LayoutPinRole = .signal
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.size = size
        self.layer = layer
        self.netID = netID
        self.role = role
    }
}
