import Foundation
import LayoutCore

/// Geometry-level edit to the direct shapes and vias of the cell an
/// `IncrementalDRCSession` verifies.
///
/// The delta deliberately cannot express structural changes — pins,
/// instances, child-cell contents, or technology edits. Those invalidate
/// state the session localizes around, so they require an explicit
/// `IncrementalDRCSession.rebuild(document:)` instead of a delta.
///
/// Ordering semantics: updated elements keep their position in the cell's
/// element order, added elements append in delta order, removed elements
/// drop out. Callers that mirror the edit into their own document must
/// apply the same semantics for violation payloads to match exactly.
public struct LayoutEditDelta: Hashable, Sendable {
    public var addedShapes: [LayoutShape]
    public var updatedShapes: [LayoutShape]
    public var removedShapeIDs: [UUID]
    public var addedVias: [LayoutVia]
    public var updatedVias: [LayoutVia]
    public var removedViaIDs: [UUID]

    public init(
        addedShapes: [LayoutShape] = [],
        updatedShapes: [LayoutShape] = [],
        removedShapeIDs: [UUID] = [],
        addedVias: [LayoutVia] = [],
        updatedVias: [LayoutVia] = [],
        removedViaIDs: [UUID] = []
    ) {
        self.addedShapes = addedShapes
        self.updatedShapes = updatedShapes
        self.removedShapeIDs = removedShapeIDs
        self.addedVias = addedVias
        self.updatedVias = updatedVias
        self.removedViaIDs = removedViaIDs
    }

    public var isEmpty: Bool {
        addedShapes.isEmpty && updatedShapes.isEmpty && removedShapeIDs.isEmpty
            && addedVias.isEmpty && updatedVias.isEmpty && removedViaIDs.isEmpty
    }
}
