import Foundation

public struct LayoutCommandArtifactManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let artifacts: [LayoutCommandArtifact]

    public init(schemaVersion: Int = 1, artifacts: [LayoutCommandArtifact]) {
        self.schemaVersion = schemaVersion
        self.artifacts = artifacts
    }
}
