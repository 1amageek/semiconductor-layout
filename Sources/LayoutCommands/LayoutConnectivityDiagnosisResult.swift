import CircuiteFoundation
import Foundation
import LayoutIO

/// Typed JSON envelope of `--diagnose-connectivity`: input evidence plus the
/// connectivity diagnosis. `status` is `passed` exactly when the design has
/// no opens and no shorts; the CLI exits 2 otherwise so agents can branch
/// without parsing.
public struct LayoutConnectivityDiagnosisResult: Codable, Sendable, Equatable {
    public let schemaVersion: SchemaVersion
    public let status: String
    public let inputArtifact: ArtifactReference
    public let technologyArtifact: ArtifactReference?
    public let diagnosis: LayoutConnectivityDiagnosisReport

    public init(
        inputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference? = nil,
        diagnosis: LayoutConnectivityDiagnosisReport
    ) {
        self.schemaVersion = .v2
        self.status = diagnosis.totals.openCount == 0 && diagnosis.totals.shortCount == 0
            ? "passed"
            : "failed"
        self.inputArtifact = inputArtifact
        self.technologyArtifact = technologyArtifact
        self.diagnosis = diagnosis
    }
}
