import Foundation
import LayoutCore

/// Owned source/world geometry; electrical connectivity is not inferred here.
public struct LayoutHierarchySnapshot: Sendable, Equatable {
    public struct Step: Sendable, Equatable, Hashable {
        public let instanceID: UUID
        public let row: Int
        public let column: Int
    }

    public struct Occurrence: Sendable, Equatable {
        public let sourceCellID: UUID
        public let parentIndex: Int?
        public let path: [Step]
        /// Outermost transform first, matching canonical geometry operations.
        public let transforms: [LayoutTransform]
        public let terminalNetIDs: [String: UUID]
        public let shapeRange: Range<Int>
        public let viaRange: Range<Int>
        public let pinRange: Range<Int>
    }

    public let documentID: UUID
    public let units: LayoutUnits
    public let rootCellID: UUID
    public let occurrences: [Occurrence]
    public let shapes: [LayoutShape]
    public let vias: [LayoutVia]
    public let pins: [LayoutPin]
    /// Full pin rectangles, retaining rotation rather than only UI envelopes.
    public let pinGeometries: [LayoutGeometry]
}
