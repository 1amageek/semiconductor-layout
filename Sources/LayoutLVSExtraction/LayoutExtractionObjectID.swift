public struct LayoutExtractionObjectID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: LayoutExtractionObjectID, rhs: LayoutExtractionObjectID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
