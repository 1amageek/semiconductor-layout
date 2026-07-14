public struct LayoutExtractionTypedParameter: Sendable, Hashable, Codable {
    public enum ValueKind: String, Sendable, Hashable, Codable {
        case number
        case integer
        case boolean
        case text
    }

    public let name: String
    public let kind: ValueKind
    public let canonicalValue: String
    public let numericValue: Double?
    public let unit: String?

    public init(
        name: String,
        kind: ValueKind,
        canonicalValue: String,
        numericValue: Double? = nil,
        unit: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.numericValue = numericValue
        self.unit = unit
    }
}
