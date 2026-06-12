import Foundation

public struct LayoutInstance: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var cellID: UUID
    public var name: String
    public var transform: LayoutTransform
    public var terminalNetIDs: [String: UUID]
    public var repetition: LayoutRepetition?

    public init(
        id: UUID = UUID(),
        cellID: UUID,
        name: String,
        transform: LayoutTransform = LayoutTransform(),
        terminalNetIDs: [String: UUID] = [:],
        repetition: LayoutRepetition? = nil
    ) {
        self.id = id
        self.cellID = cellID
        self.name = name
        self.transform = transform
        self.terminalNetIDs = terminalNetIDs
        self.repetition = repetition
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cellID
        case name
        case transform
        case terminalNetIDs
        case repetition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        cellID = try container.decode(UUID.self, forKey: .cellID)
        name = try container.decode(String.self, forKey: .name)
        transform = try container.decode(LayoutTransform.self, forKey: .transform)
        terminalNetIDs = try container.decodeIfPresent([String: UUID].self, forKey: .terminalNetIDs) ?? [:]
        repetition = try container.decodeIfPresent(LayoutRepetition.self, forKey: .repetition)
    }

    public func occurrenceTransforms() -> [LayoutTransform] {
        guard let repetition else { return [transform] }
        var transforms: [LayoutTransform] = []
        transforms.reserveCapacity(repetition.rows * repetition.columns)
        for row in 0..<repetition.rows {
            for column in 0..<repetition.columns {
                var occurrence = transform
                occurrence.translation = LayoutPoint(
                    x: transform.translation.x
                        + Double(column) * repetition.columnStep.x
                        + Double(row) * repetition.rowStep.x,
                    y: transform.translation.y
                        + Double(column) * repetition.columnStep.y
                        + Double(row) * repetition.rowStep.y
                )
                transforms.append(occurrence)
            }
        }
        return transforms
    }
}
