import Foundation
import LayoutIO

public struct LayoutDocumentConversionRequest: Codable, Sendable, Equatable {
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let outputPath: String
    public let outputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let resultPath: String?
    public let artifactManifestPath: String?

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        outputPath: String,
        outputFormat: LayoutFileFormat,
        technologyPath: String?,
        resultPath: String? = nil,
        artifactManifestPath: String? = nil
    ) {
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.outputPath = outputPath
        self.outputFormat = outputFormat
        self.technologyPath = technologyPath
        self.resultPath = resultPath
        self.artifactManifestPath = artifactManifestPath
    }
}
