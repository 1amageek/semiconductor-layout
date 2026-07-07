import Foundation
import LayoutIO

/// CLI request for the `--diagnose-connectivity` mode: which layout artifact
/// to analyze and, when the format needs one, which technology profile maps
/// its layers and vias.
public struct LayoutConnectivityDiagnosisRequest: Codable, Sendable, Equatable {
    public let inputPath: String
    public let inputFormat: LayoutFileFormat
    public let technologyPath: String?

    public init(
        inputPath: String,
        inputFormat: LayoutFileFormat,
        technologyPath: String?
    ) {
        self.inputPath = inputPath
        self.inputFormat = inputFormat
        self.technologyPath = technologyPath
    }
}
