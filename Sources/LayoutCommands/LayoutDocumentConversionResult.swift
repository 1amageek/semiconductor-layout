import Foundation
import LayoutIO

public struct LayoutDocumentConversionResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let outputPath: String
    public let outputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let inputSHA256: String
    public let inputByteCount: Int
    public let outputSHA256: String
    public let outputByteCount: Int
    public let resultPath: String?
    public let artifactManifestPath: String?
    public let summary: LayoutDocumentSummary

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        outputPath: String,
        outputFormat: LayoutFileFormat,
        technologyPath: String?,
        inputSHA256: String,
        inputByteCount: Int,
        outputSHA256: String,
        outputByteCount: Int,
        resultPath: String? = nil,
        artifactManifestPath: String? = nil,
        summary: LayoutDocumentSummary
    ) {
        self.schemaVersion = 1
        self.status = "passed"
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.outputPath = outputPath
        self.outputFormat = outputFormat
        self.technologyPath = technologyPath
        self.inputSHA256 = inputSHA256
        self.inputByteCount = inputByteCount
        self.outputSHA256 = outputSHA256
        self.outputByteCount = outputByteCount
        self.resultPath = resultPath
        self.artifactManifestPath = artifactManifestPath
        self.summary = summary
    }
}
