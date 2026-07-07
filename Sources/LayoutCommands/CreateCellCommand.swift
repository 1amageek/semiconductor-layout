import Foundation

public struct CreateCellCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let name: String
    public let makeTop: Bool

    public init(cellID: UUID, name: String, makeTop: Bool = false) {
        self.cellID = cellID
        self.name = name
        self.makeTop = makeTop
    }
}
