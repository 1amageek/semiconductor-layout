import Foundation
import LayoutCore
import LayoutIO
import LayoutVerify

public struct LayoutConstraintValidationResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let inputSHA256: String
    public let inputByteCount: Int
    public let resultPath: String?
    public let artifactManifestPath: String?
    public let summary: LayoutDocumentSummary
    public let validation: LayoutConstraintValidationSummary

    public init(
        status: String? = nil,
        inputPath: String,
        inputFormat: LayoutFileFormat,
        technologyPath: String?,
        inputSHA256: String,
        inputByteCount: Int,
        resultPath: String? = nil,
        artifactManifestPath: String? = nil,
        summary: LayoutDocumentSummary,
        validation: LayoutConstraintValidationSummary
    ) {
        self.schemaVersion = 1
        self.status = status ?? validation.status
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.technologyPath = technologyPath
        self.inputSHA256 = inputSHA256
        self.inputByteCount = inputByteCount
        self.resultPath = resultPath
        self.artifactManifestPath = artifactManifestPath
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
