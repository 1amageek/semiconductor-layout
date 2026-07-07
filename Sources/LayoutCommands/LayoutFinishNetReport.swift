import Foundation
import LayoutCore
import LayoutVerify

public struct LayoutFinishNetReport: Codable, Sendable, Equatable {
    public let commandIndex: Int
    public let command: FinishNetCommand
    public let status: String
    public let routeShapeIDs: [UUID]
    public let violationCount: Int
    public let errorCount: Int
    public let warningCount: Int
    public let routeViolationCount: Int
    public let violations: [LayoutViolation]
    public let opensBefore: Int?
    public let opensAfter: Int?
    public let shortsBefore: Int?
    public let shortsAfter: Int?
    public let verificationStatus: String?

    public init(
        commandIndex: Int,
        command: FinishNetCommand,
        status: String,
        routeShapeIDs: [UUID],
        violationCount: Int,
        errorCount: Int,
        warningCount: Int,
        routeViolationCount: Int,
        violations: [LayoutViolation],
        opensBefore: Int? = nil,
        opensAfter: Int? = nil,
        shortsBefore: Int? = nil,
        shortsAfter: Int? = nil,
        verificationStatus: String? = nil
    ) {
        self.commandIndex = commandIndex
        self.command = command
        self.status = status
        self.routeShapeIDs = routeShapeIDs
        self.violationCount = violationCount
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.routeViolationCount = routeViolationCount
        self.violations = violations
        self.opensBefore = opensBefore
        self.opensAfter = opensAfter
        self.shortsBefore = shortsBefore
        self.shortsAfter = shortsAfter
        self.verificationStatus = verificationStatus
    }
}
