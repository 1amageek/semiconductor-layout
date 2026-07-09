import Foundation
import LayoutCore

public struct AnalogArrayPlacementResult: Codable, Sendable, Equatable {
    public let status: String
    public let request: AnalogArrayPlacementRequest
    public let arrangedMemberInstanceIDs: [UUID]
    public let slotLabels: [Int]
    public let placements: [AnalogArrayPlacedInstance]
    public let persistedConstraints: [LayoutConstraint]
    public let boundingBox: LayoutRect

    public init(
        status: String,
        request: AnalogArrayPlacementRequest,
        arrangedMemberInstanceIDs: [UUID],
        slotLabels: [Int],
        placements: [AnalogArrayPlacedInstance],
        persistedConstraints: [LayoutConstraint],
        boundingBox: LayoutRect
    ) {
        self.status = status
        self.request = request
        self.arrangedMemberInstanceIDs = arrangedMemberInstanceIDs
        self.slotLabels = slotLabels
        self.placements = placements
        self.persistedConstraints = persistedConstraints
        self.boundingBox = boundingBox
    }
}
