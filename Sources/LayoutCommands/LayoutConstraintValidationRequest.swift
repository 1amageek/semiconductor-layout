import Foundation
import LayoutIO

public struct LayoutConstraintValidationRequest: Codable, Sendable, Equatable {
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let technologyPath: String?
    public let cellID: UUID?
    public let tolerance: Double?
    public let resultPath: String?
    public let artifactManifestPath: String?

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        technologyPath: String? = nil,
        cellID: UUID? = nil,
        tolerance: Double? = nil,
        resultPath: String? = nil,
        artifactManifestPath: String? = nil
    ) {
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.technologyPath = technologyPath
        self.cellID = cellID
        self.tolerance = tolerance
        self.resultPath = resultPath
        self.artifactManifestPath = artifactManifestPath
    }
}
