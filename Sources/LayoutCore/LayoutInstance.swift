import Foundation

public struct LayoutInstance: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var cellID: UUID
    public var name: String
    public var transform: LayoutTransform
    public var terminalNetIDs: [String: UUID]

    public init(
        id: UUID = UUID(),
        cellID: UUID,
        name: String,
        transform: LayoutTransform = LayoutTransform(),
        terminalNetIDs: [String: UUID] = [:]
    ) {
        self.id = id
        self.cellID = cellID
        self.name = name
        self.transform = transform
        self.terminalNetIDs = terminalNetIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cellID
        case name
        case transform
        case terminalNetIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cellID = try container.decode(UUID.self, forKey: .cellID)
        name = try container.decode(String.self, forKey: .name)
        transform = try container.decode(LayoutTransform.self, forKey: .transform)
        terminalNetIDs = try container.decodeIfPresent([String: UUID].self, forKey: .terminalNetIDs) ?? [:]
    }
}
