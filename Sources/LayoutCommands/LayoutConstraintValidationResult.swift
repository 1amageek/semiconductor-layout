import CircuiteFoundation
import Foundation
import LayoutCore
import LayoutIO
import LayoutVerify

public struct LayoutConstraintValidationResult: Codable, Sendable, Equatable {
    public let schemaVersion: SchemaVersion
    public let status: String
    public let inputArtifact: ArtifactReference
    public let technologyArtifact: ArtifactReference?
    public let summary: LayoutDocumentSummary
    public let validation: LayoutConstraintValidationSummary

    public init(
        status: String? = nil,
        inputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference? = nil,
        summary: LayoutDocumentSummary,
        validation: LayoutConstraintValidationSummary
    ) {
        self.schemaVersion = .v2
        self.status = status ?? validation.status
        self.inputArtifact = inputArtifact
        self.technologyArtifact = technologyArtifact
        self.summary = summary
        self.validation = validation
    }
}

public struct LayoutConstraintValidationSummary: Codable, Sendable, Equatable {
    public let status: String
    public let cellID: UUID
    public let cellName: String
    public let tolerance: Double
    public let constraintCount: Int
    public let violationCount: Int
    public let errorCount: Int
    public let warningCount: Int
    public let kindViolationCounts: [String: Int]
    public let violations: [LayoutConstraintViolationSummary]

    public init(
        status: String,
        cellID: UUID,
        cellName: String,
        tolerance: Double,
        constraintCount: Int,
        violationCount: Int,
        errorCount: Int,
        warningCount: Int,
        kindViolationCounts: [String: Int],
        violations: [LayoutConstraintViolationSummary]
    ) {
        self.status = status
        self.cellID = cellID
        self.cellName = cellName
        self.tolerance = tolerance
        self.constraintCount = constraintCount
        self.violationCount = violationCount
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.kindViolationCounts = kindViolationCounts
        self.violations = violations
    }
}

public struct LayoutConstraintViolationSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: String
    public let constraintIndex: Int
    public let severity: String
    public let message: String
    public let region: LayoutRect
    public let memberIDs: [UUID]
    public let measured: Double?
    public let required: Double?

    public init(violation: LayoutConstraintViolation) {
        self.id = violation.id
        self.kind = violation.kind.rawValue
        self.constraintIndex = violation.constraintIndex
        self.severity = violation.severity.rawValue
        self.message = violation.message
        self.region = violation.region
        self.memberIDs = violation.memberIDs
        self.measured = violation.measured
        self.required = violation.required
    }
}
