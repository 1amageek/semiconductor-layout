import Foundation
import LayoutIO

public struct LayoutDocumentInspectionRequest: Codable, Sendable, Equatable {
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let resultPath: String?
    public let artifactManifestPath: String?

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        technologyPath: String?,
        resultPath: String? = nil,
        artifactManifestPath: String? = nil
    ) {
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.technologyPath = technologyPath
        self.resultPath = resultPath
        self.artifactManifestPath = artifactManifestPath
    }
}
