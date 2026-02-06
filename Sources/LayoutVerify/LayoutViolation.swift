import Foundation
import LayoutCore

public struct LayoutViolation: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var kind: LayoutViolationKind
    public var message: String
    public var layer: LayoutLayerID?
    public var region: LayoutRect

    public init(
        id: UUID = UUID(),
        kind: LayoutViolationKind,
        message: String,
        layer: LayoutLayerID? = nil,
        region: LayoutRect = .zero
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.layer = layer
        self.region = region
    }
}
