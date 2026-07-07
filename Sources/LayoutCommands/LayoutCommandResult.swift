import Foundation

public struct LayoutCommandResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let commandCount: Int
    public let appliedCommands: [LayoutAppliedCommand]
    public let outputDocumentPath: String
    public let outputDocumentSHA256: String
    public let outputDocumentByteCount: Int
    public let artifactManifestPath: String
    public let cellCount: Int
    public let shapeCount: Int
    public let viaCount: Int
    public let labelCount: Int
    public let netCount: Int

    public init(
        schemaVersion: Int = 1,
        status: String,
        commandCount: Int,
        appliedCommands: [LayoutAppliedCommand],
        outputDocumentPath: String,
        outputDocumentSHA256: String,
        outputDocumentByteCount: Int,
        artifactManifestPath: String,
        cellCount: Int,
        shapeCount: Int,
        viaCount: Int,
        labelCount: Int,
        netCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.commandCount = commandCount
        self.appliedCommands = appliedCommands
        self.outputDocumentPath = outputDocumentPath
        self.outputDocumentSHA256 = outputDocumentSHA256
        self.outputDocumentByteCount = outputDocumentByteCount
        self.artifactManifestPath = artifactManifestPath
        self.cellCount = cellCount
        self.shapeCount = shapeCount
        self.viaCount = viaCount
        self.labelCount = labelCount
        self.netCount = netCount
    }
}
