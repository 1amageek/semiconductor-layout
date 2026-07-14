public struct LayoutExtractionDeviceRule: Sendable, Hashable, Codable {
    public let ruleID: String
    public let family: String
    public let model: String
    public let recognitionExpressions: [String]
    public let parameterExpressions: [String]
    public let sourceLocation: LayoutExtractionSourceLocation
    public let sourceText: String

    public init(
        ruleID: String,
        family: String,
        model: String,
        recognitionExpressions: [String],
        parameterExpressions: [String],
        sourceLocation: LayoutExtractionSourceLocation,
        sourceText: String
    ) {
        self.ruleID = ruleID
        self.family = family
        self.model = model
        self.recognitionExpressions = recognitionExpressions
        self.parameterExpressions = parameterExpressions
        self.sourceLocation = sourceLocation
        self.sourceText = sourceText
    }
}
