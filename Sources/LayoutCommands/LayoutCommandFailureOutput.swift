public struct LayoutCommandFailureOutput: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let errorCode: String
    public let reason: String
    public let message: String
    public let suggestedActions: [String]

    public init(
        schemaVersion: Int = 1,
        status: String = "failed",
        errorCode: String,
        reason: String? = nil,
        message: String,
        suggestedActions: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.errorCode = errorCode
        self.reason = reason ?? errorCode
        self.message = message
        self.suggestedActions = suggestedActions
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case errorCode
        case reason
        case message
        case suggestedActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        status = try container.decode(String.self, forKey: .status)
        errorCode = try container.decode(String.self, forKey: .errorCode)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? errorCode
        message = try container.decode(String.self, forKey: .message)
        suggestedActions = try container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? []
    }
}
