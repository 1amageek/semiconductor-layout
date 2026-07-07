import Foundation

public struct AddNetCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let netID: UUID
    public let name: String
    public let currentSpec: Double?

    public init(cellID: UUID, netID: UUID, name: String, currentSpec: Double? = nil) {
        self.cellID = cellID
        self.netID = netID
        self.name = name
        self.currentSpec = currentSpec
    }
}
