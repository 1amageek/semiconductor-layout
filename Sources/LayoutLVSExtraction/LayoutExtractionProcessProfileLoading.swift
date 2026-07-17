import Foundation

public protocol LayoutExtractionProcessProfileLoading: Sendable {
    func load(
        profileURL: URL,
        extractionDeckURL: URL,
        expectedProcessProfileID: String?
    ) throws -> LayoutExtractionProcessProfile
}
