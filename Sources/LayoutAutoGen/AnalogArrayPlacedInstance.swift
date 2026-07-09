import Foundation
import LayoutCore

public struct AnalogArrayPlacedInstance: Codable, Sendable, Equatable {
    public let instanceID: UUID
    public let patternLabel: Int
    public let slotIndex: Int
    public let slotCenter: LayoutPoint
    public let previousTransform: LayoutTransform
    public let proposedTransform: LayoutTransform
    public let bounds: LayoutRect

    public init(
        instanceID: UUID,
        patternLabel: Int,
        slotIndex: Int,
        slotCenter: LayoutPoint,
        previousTransform: LayoutTransform,
        proposedTransform: LayoutTransform,
        bounds: LayoutRect
    ) {
        self.instanceID = instanceID
        self.patternLabel = patternLabel
        self.slotIndex = slotIndex
        self.slotCenter = slotCenter
        self.previousTransform = previousTransform
        self.proposedTransform = proposedTransform
        self.bounds = bounds
    }
}
