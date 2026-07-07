import Foundation
import LayoutCore
import LayoutVerify

public struct LayoutRepairSweepReport: Codable, Sendable, Equatable {
    public struct AppliedRepair: Codable, Sendable, Equatable {
        public let violationID: UUID
        public let summary: String
        public let addedShapeIDs: [UUID]
        public let updatedShapeIDs: [UUID]
        public let removedShapeIDs: [UUID]
        public let addedViaIDs: [UUID]
        public let updatedViaIDs: [UUID]
        public let removedViaIDs: [UUID]

        public init(repair: LayoutRepair) {
            self.violationID = repair.violationID
            self.summary = repair.summary
            self.addedShapeIDs = repair.delta.addedShapes.map(\.id)
            self.updatedShapeIDs = repair.delta.updatedShapes.map(\.id)
            self.removedShapeIDs = repair.delta.removedShapeIDs
            self.addedViaIDs = repair.delta.addedVias.map(\.id)
            self.updatedViaIDs = repair.delta.updatedVias.map(\.id)
            self.removedViaIDs = repair.delta.removedViaIDs
        }
    }

    public struct Residual: Codable, Sendable, Equatable {
        public let violation: LayoutViolation
        public let reasonCode: String
        public let reason: String

        public init(violation: LayoutViolation, reason: LayoutRepairInfeasibility) {
            self.violation = violation
            self.reasonCode = Self.reasonCode(for: reason)
            self.reason = Self.reasonMessage(for: reason)
        }

        private static func reasonCode(for reason: LayoutRepairInfeasibility) -> String {
            switch reason {
            case .unsupportedKind:
                return "unsupported_kind"
            case .blockedByNeighbours:
                return "blocked_by_neighbours"
            case .nonRectangularGeometry:
                return "non_rectangular_geometry"
            case .childGeometry:
                return "child_geometry"
            case .missingContext:
                return "missing_context"
            }
        }

        private static func reasonMessage(for reason: LayoutRepairInfeasibility) -> String {
            switch reason {
            case .unsupportedKind(let message):
                return message
            case .blockedByNeighbours:
                return "Every verified candidate created or retained blocking DRC violations."
            case .nonRectangularGeometry:
                return "The violating geometry is not rectangular."
            case .childGeometry:
                return "The violation references child or otherwise non-editable geometry."
            case .missingContext(let message):
                return message
            }
        }
    }

    public let schemaVersion: Int
    public let status: String
    public let commandIndex: Int
    public let cellID: UUID
    public let technologyPath: String
    public let budget: Int
    public let reachedFixedPoint: Bool
    public let appliedRepairCount: Int
    public let residualViolationCount: Int
    public let appliedRepairs: [AppliedRepair]
    public let residuals: [Residual]

    public init(
        schemaVersion: Int = 1,
        commandIndex: Int,
        cellID: UUID,
        technologyPath: String,
        budget: Int,
        reachedFixedPoint: Bool,
        appliedRepairs: [AppliedRepair],
        residuals: [Residual]
    ) {
        self.schemaVersion = schemaVersion
        self.status = Self.status(reachedFixedPoint: reachedFixedPoint, residuals: residuals)
        self.commandIndex = commandIndex
        self.cellID = cellID
        self.technologyPath = technologyPath
        self.budget = budget
        self.reachedFixedPoint = reachedFixedPoint
        self.appliedRepairCount = appliedRepairs.count
        self.residualViolationCount = residuals.count
        self.appliedRepairs = appliedRepairs
        self.residuals = residuals
    }

    public init(
        commandIndex: Int,
        command: FixAllViolationsCommand,
        repairs: [LayoutRepair],
        sweep: LayoutRepairSweep
    ) {
        self.init(
            commandIndex: commandIndex,
            cellID: command.cellID,
            technologyPath: command.technologyPath,
            budget: command.budget,
            reachedFixedPoint: sweep.reachedFixedPoint,
            appliedRepairs: repairs.map(AppliedRepair.init),
            residuals: sweep.residuals.map { residual in
                Residual(violation: residual.violation, reason: residual.reason)
            }
        )
    }

    private static func status(reachedFixedPoint: Bool, residuals: [Residual]) -> String {
        if reachedFixedPoint && residuals.isEmpty {
            return "clean"
        }
        if reachedFixedPoint {
            return "fixed_point_with_residuals"
        }
        return "budget_exhausted"
    }
}
