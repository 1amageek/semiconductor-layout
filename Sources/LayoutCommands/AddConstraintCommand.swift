import Foundation
import LayoutCore

public struct AddConstraintCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let constraint: LayoutConstraint

    public init(cellID: UUID, constraint: LayoutConstraint) {
        self.cellID = cellID
        self.constraint = constraint
    }
}
