import Foundation

public enum LayoutEngineRole: String, Sendable, Codable, Equatable {
    case placement
    case routing
    case deviceCellGeneration
    case postRouteVerification
}

public struct LayoutEngineDescriptor: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let role: LayoutEngineRole
    public let summary: String
    public let isDeterministic: Bool
    public let source: String

    public init(
        id: String,
        name: String,
        version: String,
        role: LayoutEngineRole,
        summary: String,
        isDeterministic: Bool,
        source: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.role = role
        self.summary = summary
        self.isDeterministic = isDeterministic
        self.source = source
    }
}
