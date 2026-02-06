import Foundation

public struct LayoutInstance: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var cellID: UUID
    public var name: String
    public var transform: LayoutTransform

    public init(
        id: UUID = UUID(),
        cellID: UUID,
        name: String,
        transform: LayoutTransform = LayoutTransform()
    ) {
        self.id = id
        self.cellID = cellID
        self.name = name
        self.transform = transform
    }
}
