import Foundation

public struct LayoutVia: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var viaDefinitionID: String
    public var position: LayoutPoint
    public var netID: UUID?

    public init(
        id: UUID = UUID(),
        viaDefinitionID: String,
        position: LayoutPoint,
        netID: UUID? = nil
    ) {
        self.id = id
        self.viaDefinitionID = viaDefinitionID
        self.position = position
        self.netID = netID
    }
}
