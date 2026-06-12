import Foundation

public struct LayoutNet: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    /// Operating current in mA, when the design declares one; drives the
    /// electromigration width check.
    public var currentSpec: Double?

    public init(id: UUID = UUID(), name: String, currentSpec: Double? = nil) {
        self.id = id
        self.name = name
        self.currentSpec = currentSpec
    }
}
