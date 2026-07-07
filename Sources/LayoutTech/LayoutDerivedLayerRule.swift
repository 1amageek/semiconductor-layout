import Foundation
import LayoutCore

public struct LayoutDerivedLayerRule: Hashable, Sendable, Codable {
    public enum Operation: String, Hashable, Sendable, Codable {
        case intersection
        case union
        case difference
        case xor
        case grow
        case growMin = "grow-min"
        case shrink
        case bridge
        case close
        case bloatAll = "bloat-all"
        case cellBoundary = "cell-boundary"
    }

    public var id: String
    public var targetLayer: LayoutLayerID
    public var sourceLayers: [LayoutLayerID]
    public var operation: Operation
    public var operationDistance: Double?
    public var operationWidth: Double?
    public var primarySourceLayerCount: Int?

    public init(
        id: String,
        targetLayer: LayoutLayerID,
        sourceLayers: [LayoutLayerID],
        operation: Operation,
        operationDistance: Double? = nil,
        operationWidth: Double? = nil,
        primarySourceLayerCount: Int? = nil
    ) {
        self.id = id
        self.targetLayer = targetLayer
        self.sourceLayers = sourceLayers
        self.operation = operation
        self.operationDistance = operationDistance
        self.operationWidth = operationWidth
        self.primarySourceLayerCount = primarySourceLayerCount
    }
}
