import Foundation
import LayoutCore

public struct AddInstanceCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let instanceID: UUID
    public let referencedCellID: UUID
    public let name: String
    public let transform: LayoutTransform
    public let terminalNetIDs: [String: UUID]
    public let repetition: LayoutRepetition?

    public init(
        cellID: UUID,
        instanceID: UUID,
        referencedCellID: UUID,
        name: String,
        transform: LayoutTransform = LayoutTransform(),
        terminalNetIDs: [String: UUID] = [:],
        repetition: LayoutRepetition? = nil
    ) {
        self.cellID = cellID
        self.instanceID = instanceID
        self.referencedCellID = referencedCellID
        self.name = name
        self.transform = transform
        self.terminalNetIDs = terminalNetIDs
        self.repetition = repetition
    }
}
