import CircuiteFoundation
import Foundation

public struct LayoutCommandResult: Codable, Sendable, Equatable {
    public let schemaVersion: SchemaVersion
    public let status: String
    public let commandCount: Int
    public let appliedCommands: [LayoutAppliedCommand]
    public let outputArtifact: ArtifactReference
    public let cellCount: Int
    public let shapeCount: Int
    public let viaCount: Int
    public let labelCount: Int
    public let netCount: Int

    public init(
        schemaVersion: SchemaVersion = .v2,
        status: String,
        commandCount: Int,
        appliedCommands: [LayoutAppliedCommand],
        outputArtifact: ArtifactReference,
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
        self.outputArtifact = outputArtifact
        self.cellCount = cellCount
        self.shapeCount = shapeCount
        self.viaCount = viaCount
        self.labelCount = labelCount
        self.netCount = netCount
    }
}
