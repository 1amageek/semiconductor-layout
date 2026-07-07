import Foundation

public struct LayoutAppliedCommand: Codable, Sendable, Equatable {
    public let index: Int
    public let kind: LayoutCommandKind
    public let cellID: UUID?
    public let entityID: UUID?

    public init(index: Int, kind: LayoutCommandKind, cellID: UUID?, entityID: UUID?) {
        self.index = index
        self.kind = kind
        self.cellID = cellID
        self.entityID = entityID
    }
}
