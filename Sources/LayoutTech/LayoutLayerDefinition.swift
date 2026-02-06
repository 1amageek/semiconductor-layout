import Foundation
import LayoutCore

public struct LayoutLayerDefinition: Hashable, Sendable, Codable {
    public var id: LayoutLayerID
    public var displayName: String
    public var gdsLayer: Int
    public var gdsDatatype: Int
    public var color: LayoutColor
    public var preferredDirection: LayoutPreferredDirection
    public var visibleByDefault: Bool

    public init(
        id: LayoutLayerID,
        displayName: String,
        gdsLayer: Int,
        gdsDatatype: Int,
        color: LayoutColor,
        preferredDirection: LayoutPreferredDirection = .none,
        visibleByDefault: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.gdsLayer = gdsLayer
        self.gdsDatatype = gdsDatatype
        self.color = color
        self.preferredDirection = preferredDirection
        self.visibleByDefault = visibleByDefault
    }
}
