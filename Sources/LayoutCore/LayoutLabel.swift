import Foundation

public struct LayoutLabel: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var text: String
    public var position: LayoutPoint
    public var layer: LayoutLayerID
    public var netID: UUID?

    public init(
        id: UUID = UUID(),
        text: String,
        position: LayoutPoint,
        layer: LayoutLayerID,
        netID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.position = position
        self.layer = layer
        self.netID = netID
    }
}
