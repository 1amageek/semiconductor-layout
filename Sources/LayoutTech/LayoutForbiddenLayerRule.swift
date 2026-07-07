import Foundation
import LayoutCore

public struct LayoutForbiddenLayerRule: Hashable, Sendable, Codable {
    public var id: String
    public var layer: LayoutLayerID
    public var reason: String?

    public init(
        id: String,
        layer: LayoutLayerID,
        reason: String? = nil
    ) {
        self.id = id
        self.layer = layer
        self.reason = reason
    }
}
