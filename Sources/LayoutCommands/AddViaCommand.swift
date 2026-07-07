import Foundation
import LayoutCore

public struct AddViaCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let viaID: UUID
    public let viaDefinitionID: String
    public let position: LayoutPoint
    public let netID: UUID?

    public init(
        cellID: UUID,
        viaID: UUID,
        viaDefinitionID: String,
        position: LayoutPoint,
        netID: UUID? = nil
    ) {
        self.cellID = cellID
        self.viaID = viaID
        self.viaDefinitionID = viaDefinitionID
        self.position = position
        self.netID = netID
    }
}
