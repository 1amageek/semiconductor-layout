public enum LayoutExtractionDeckCompilerError: Error, Sendable, Hashable {
    case unreadableSource(String)
    case missingExtractSection
    case noDeviceRules
    case malformedDeviceDirective(line: Int, directive: String)
}
