import Foundation

public struct LayoutNet: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
