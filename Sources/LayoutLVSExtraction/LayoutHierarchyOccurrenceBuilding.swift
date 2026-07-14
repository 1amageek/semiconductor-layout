import Foundation
import LayoutCore

public protocol LayoutHierarchyOccurrenceBuilding: Sendable {
    func build(
        document: LayoutDocument,
        topCellID: UUID,
        maximumOccurrenceCount: Int
    ) throws -> LayoutHierarchyInventory
}
