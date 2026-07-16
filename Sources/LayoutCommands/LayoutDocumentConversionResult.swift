import CircuiteFoundation
import Foundation
import LayoutIO

public struct LayoutDocumentConversionResult: Codable, Sendable, Equatable {
    public let schemaVersion: SchemaVersion
    public let status: String
    public let inputArtifact: ArtifactReference
    public let outputArtifact: ArtifactReference
    public let technologyArtifact: ArtifactReference?
    public let summary: LayoutDocumentSummary

    public init(
        inputArtifact: ArtifactReference,
        outputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference? = nil,
        summary: LayoutDocumentSummary
    ) {
        self.schemaVersion = .v2
        self.status = "passed"
        self.inputArtifact = inputArtifact
        self.outputArtifact = outputArtifact
        self.technologyArtifact = technologyArtifact
        self.summary = summary
    }
}
