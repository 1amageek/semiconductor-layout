import Foundation
import LayoutAutoGen

public struct PlaceAnalogArrayCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let request: AnalogArrayPlacementRequest
    public let reportPath: String?

    public init(
        cellID: UUID,
        request: AnalogArrayPlacementRequest,
        reportPath: String? = nil
    ) {
        self.cellID = cellID
        self.request = request
        self.reportPath = reportPath
    }
}
