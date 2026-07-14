public struct LayoutExtractionUnsupportedDirective: Sendable, Hashable, Codable {
    public let reasonCode: String
    public let family: String?
    public let directive: String
    public let sourceLocation: LayoutExtractionSourceLocation

    public init(
        reasonCode: String,
        family: String? = nil,
        directive: String,
        sourceLocation: LayoutExtractionSourceLocation
    ) {
        self.reasonCode = reasonCode
        self.family = family
        self.directive = directive
        self.sourceLocation = sourceLocation
    }
}
