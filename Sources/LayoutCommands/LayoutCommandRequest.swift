import Foundation

public struct LayoutCommandRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let documentID: UUID?
    public let documentName: String?
    public let inputDocumentPath: String?
    public let outputDocumentPath: String
    public let artifactManifestPath: String?
    public let resultPath: String?
    public let commands: [LayoutCommand]

    public init(
        schemaVersion: Int = 1,
        documentID: UUID? = nil,
        documentName: String? = nil,
        inputDocumentPath: String? = nil,
        outputDocumentPath: String,
        artifactManifestPath: String? = nil,
        resultPath: String? = nil,
        commands: [LayoutCommand]
    ) {
        self.schemaVersion = schemaVersion
        self.documentID = documentID
        self.documentName = documentName
        self.inputDocumentPath = inputDocumentPath
        self.outputDocumentPath = outputDocumentPath
        self.artifactManifestPath = artifactManifestPath
        self.resultPath = resultPath
        self.commands = commands
    }
}
