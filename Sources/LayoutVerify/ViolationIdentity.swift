import Foundation
import LayoutCore

/// Position-independent identity of a violation: what is violated and
/// between which design elements, ignoring where the marker currently
/// sits and how badly the rule is missed.
///
/// Interactive editing needs to distinguish "the violation this drag
/// started with, still unresolved" from "a violation this drag created".
/// A violation that merely moves or changes its measured value with the
/// dragged geometry keeps its identity; one involving a new element pair
/// or a new rule is new.
public struct ViolationIdentity: Hashable, Sendable {
    public let kind: LayoutViolationKind
    public let ruleID: String?
    public let layer: LayoutLayerID?
    public let shapeIDs: [UUID]
    public let viaIDs: [UUID]
    public let pinIDs: [UUID]
    public let netIDs: [UUID]

    public init(of violation: LayoutViolation) {
        self.kind = violation.kind
        self.ruleID = violation.ruleID
        self.layer = violation.layer
        self.shapeIDs = violation.shapeIDs.sorted { $0.uuidString < $1.uuidString }
        self.viaIDs = violation.viaIDs.sorted { $0.uuidString < $1.uuidString }
        self.pinIDs = violation.pinIDs.sorted { $0.uuidString < $1.uuidString }
        self.netIDs = violation.netIDs.sorted { $0.uuidString < $1.uuidString }
    }

    /// Whether the violation involves any of the given shape IDs.
    public func involves(shapeIDs ids: Set<UUID>) -> Bool {
        shapeIDs.contains { ids.contains($0) }
    }
}
