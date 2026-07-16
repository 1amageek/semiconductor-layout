import CircuiteFoundation
import Foundation
import LayoutCore
import LayoutIO
import LayoutVerify

public struct LayoutDocumentInspectionResult: Codable, Sendable, Equatable {
    public let schemaVersion: SchemaVersion
    public let status: String
    public let inputArtifact: ArtifactReference
    public let technologyArtifact: ArtifactReference?
    public let summary: LayoutDocumentSummary
    public let verification: LayoutDocumentInspectionVerification?

    public init(
        status: String? = nil,
        inputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference? = nil,
        summary: LayoutDocumentSummary,
        verification: LayoutDocumentInspectionVerification? = nil
    ) {
        self.schemaVersion = .v2
        self.status = status ?? verification?.status ?? "unverified"
        self.inputArtifact = inputArtifact
        self.technologyArtifact = technologyArtifact
        self.summary = summary
        self.verification = verification
    }
}

public struct LayoutDocumentInspectionVerification: Codable, Sendable, Equatable {
    public let status: String
    public let topCellID: UUID
    public let drc: LayoutDocumentInspectionDRCSummary
    public let connectivity: LayoutDocumentInspectionConnectivitySummary

    public init(
        status: String,
        topCellID: UUID,
        drc: LayoutDocumentInspectionDRCSummary,
        connectivity: LayoutDocumentInspectionConnectivitySummary
    ) {
        self.status = status
        self.topCellID = topCellID
        self.drc = drc
        self.connectivity = connectivity
    }
}

public struct LayoutDocumentInspectionDRCSummary: Codable, Sendable, Equatable {
    public let violationCount: Int
    public let errorCount: Int
    public let warningCount: Int
    public let diagnosticCount: Int
    public let ruleViolationCounts: [String: Int]
    public let kindViolationCounts: [String: Int]
    public let violations: [LayoutDocumentInspectionViolationSummary]
    public let diagnostics: [LayoutDRCDiagnostic]

    public init(
        violationCount: Int,
        errorCount: Int,
        warningCount: Int,
        diagnosticCount: Int,
        ruleViolationCounts: [String: Int],
        kindViolationCounts: [String: Int],
        violations: [LayoutDocumentInspectionViolationSummary],
        diagnostics: [LayoutDRCDiagnostic]
    ) {
        self.violationCount = violationCount
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.diagnosticCount = diagnosticCount
        self.ruleViolationCounts = ruleViolationCounts
        self.kindViolationCounts = kindViolationCounts
        self.violations = violations
        self.diagnostics = diagnostics
    }
}

public struct LayoutDocumentInspectionViolationSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: String
    public let ruleID: String?
    public let severity: String
    public let message: String
    public let layer: LayoutLayerID?
    public let region: LayoutRect
    public let measured: Double?
    public let required: Double?
    public let unit: String?
    public let shapeIDs: [UUID]
    public let viaIDs: [UUID]
    public let pinIDs: [UUID]
    public let netIDs: [UUID]
    public let suggestedFix: String?

    public init(
        id: UUID,
        kind: String,
        ruleID: String?,
        severity: String,
        message: String,
        layer: LayoutLayerID?,
        region: LayoutRect,
        measured: Double?,
        required: Double?,
        unit: String?,
        shapeIDs: [UUID],
        viaIDs: [UUID],
        pinIDs: [UUID],
        netIDs: [UUID],
        suggestedFix: String?
    ) {
        self.id = id
        self.kind = kind
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.layer = layer
        self.region = region
        self.measured = measured
        self.required = required
        self.unit = unit
        self.shapeIDs = shapeIDs
        self.viaIDs = viaIDs
        self.pinIDs = pinIDs
        self.netIDs = netIDs
        self.suggestedFix = suggestedFix
    }
}

public struct LayoutDocumentInspectionConnectivitySummary: Codable, Sendable, Equatable {
    public let extractedNetCount: Int
    public let shortCount: Int
    public let openCount: Int
    public let flylineCount: Int

    public init(
        extractedNetCount: Int,
        shortCount: Int,
        openCount: Int,
        flylineCount: Int
    ) {
        self.extractedNetCount = extractedNetCount
        self.shortCount = shortCount
        self.openCount = openCount
        self.flylineCount = flylineCount
    }
}
