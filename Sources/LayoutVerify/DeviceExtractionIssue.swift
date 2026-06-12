import Foundation
import LayoutCore

public enum DeviceExtractionIssueKind: String, Hashable, Sendable, Codable {
    case ambiguousDeviceType
    case missingTerminal
    case unrecognizedChannel
    /// One connected island carries more than one declared net.
    case shortedNet
    /// One declared net or pin name spans several disconnected islands.
    case openNet
    /// Two pins share a name but resolve to different nets.
    case conflictingPort
}

public struct DeviceExtractionIssue: Hashable, Sendable, Codable {
    public var kind: DeviceExtractionIssueKind
    public var message: String
    public var region: LayoutRect
    public var shapeIDs: [UUID]

    public init(
        kind: DeviceExtractionIssueKind,
        message: String,
        region: LayoutRect,
        shapeIDs: [UUID] = []
    ) {
        self.kind = kind
        self.message = message
        self.region = region
        self.shapeIDs = shapeIDs
    }
}
