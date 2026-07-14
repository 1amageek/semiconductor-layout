import Foundation

public enum LayoutHierarchyOccurrenceBuilderError: Error, Sendable, Hashable {
    case duplicateCellID(UUID)
    case missingTopCell(UUID)
    case invalidOccurrenceLimit(Int)
}
