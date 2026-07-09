import Foundation
import LayoutAutoGen

public struct AddGuardRingCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let technologyPath: String
    public let request: GuardRingRequest
    public let reportPath: String?

    public init(
        cellID: UUID,
        technologyPath: String,
        request: GuardRingRequest,
        reportPath: String? = nil
    ) {
        self.cellID = cellID
        self.technologyPath = technologyPath
        self.request = request
        self.reportPath = reportPath
    }
}
