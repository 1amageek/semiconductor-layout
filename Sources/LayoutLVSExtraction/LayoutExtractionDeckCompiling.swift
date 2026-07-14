import Foundation

public protocol LayoutExtractionDeckCompiling: Sendable {
    func compile(
        sourceURL: URL,
        processID: String,
        processProfileID: String
    ) throws -> LayoutExtractionDeck
}
