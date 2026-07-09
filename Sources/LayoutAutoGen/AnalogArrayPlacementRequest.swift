import Foundation
import LayoutCore

public struct AnalogArrayPlacementRequest: Codable, Sendable, Equatable {
    public var memberInstanceIDs: [UUID]
    public var pattern: [Int]
    public var slotLabels: [Int]?
    public var firstSlotCenter: LayoutPoint
    public var slotPitch: LayoutSize
    public var persistedConstraints: [AnalogArrayConstraintKind]

    public init(
        memberInstanceIDs: [UUID],
        pattern: [Int],
        slotLabels: [Int]? = nil,
        firstSlotCenter: LayoutPoint,
        slotPitch: LayoutSize,
        persistedConstraints: [AnalogArrayConstraintKind] = [.commonCentroid, .interdigitated, .matching]
    ) {
        self.memberInstanceIDs = memberInstanceIDs
        self.pattern = pattern
        self.slotLabels = slotLabels
        self.firstSlotCenter = firstSlotCenter
        self.slotPitch = slotPitch
        self.persistedConstraints = persistedConstraints
    }
}
