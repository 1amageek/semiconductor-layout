import Foundation
import LayoutIO

/// Typed JSON envelope of `--diagnose-connectivity`: input evidence plus the
/// connectivity diagnosis. `status` is `passed` exactly when the design has
/// no opens and no shorts; the CLI exits 2 otherwise so agents can branch
/// without parsing.
public struct LayoutConnectivityDiagnosisResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let inputSHA256: String
    public let inputByteCount: Int
    public let diagnosis: LayoutConnectivityDiagnosisReport

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        technologyPath: String?,
        inputSHA256: String,
        inputByteCount: Int,
        diagnosis: LayoutConnectivityDiagnosisReport
    ) {
        self.schemaVersion = 1
        self.status = diagnosis.totals.openCount == 0 && diagnosis.totals.shortCount == 0
            ? "passed"
            : "failed"
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.technologyPath = technologyPath
        self.inputSHA256 = inputSHA256
        self.inputByteCount = inputByteCount
        self.diagnosis = diagnosis
    }
}
