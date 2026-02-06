import Foundation

public struct LayoutLayerID: Hashable, Sendable, Codable {
    public var name: String
    public var purpose: String

    public init(name: String, purpose: String) {
        self.name = name
        self.purpose = purpose
    }
}
