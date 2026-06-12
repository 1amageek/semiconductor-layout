import Foundation

/// One executed goal command with the verdicts around it — the auditable
/// unit of the goal log. A replayed log reproduces these records.
public struct LayoutGoalRecord: Sendable, Equatable {
    public var command: LayoutGoalCommand
    public var succeeded: Bool
    public var violationsBefore: Int
    public var violationsAfter: Int
    public var opensBefore: Int
    public var opensAfter: Int
    public var lvsMatchedBefore: Int
    public var lvsMatchedAfter: Int

    public init(
        command: LayoutGoalCommand,
        succeeded: Bool,
        violationsBefore: Int,
        violationsAfter: Int,
        opensBefore: Int,
        opensAfter: Int,
        lvsMatchedBefore: Int,
        lvsMatchedAfter: Int
    ) {
        self.command = command
        self.succeeded = succeeded
        self.violationsBefore = violationsBefore
        self.violationsAfter = violationsAfter
        self.opensBefore = opensBefore
        self.opensAfter = opensAfter
        self.lvsMatchedBefore = lvsMatchedBefore
        self.lvsMatchedAfter = lvsMatchedAfter
    }
}
