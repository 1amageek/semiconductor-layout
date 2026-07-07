import Foundation

public struct FixAllViolationsCommand: Codable, Sendable, Equatable {
    public let cellID: UUID
    public let technologyPath: String
    public let reportPath: String
    public let budget: Int

    public init(cellID: UUID, technologyPath: String, reportPath: String, budget: Int = 64) {
        self.cellID = cellID
        self.technologyPath = technologyPath
        self.reportPath = reportPath
        self.budget = budget
    }
}
