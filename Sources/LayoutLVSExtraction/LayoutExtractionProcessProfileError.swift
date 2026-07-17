import Foundation

public enum LayoutExtractionProcessProfileError: Error, Sendable, Hashable, LocalizedError {
    case missingProfileArtifact(path: String)
    case unreadableProfileArtifact(path: String, reason: String)
    case invalidProfileArtifact(path: String, reason: String)
    case unsupportedSchemaVersion(actual: Int, supported: Int)
    case processProfileMismatch(expected: String, actual: String)
    case missingExtractionDeck(path: String)
    case unreadableExtractionDeck(path: String, reason: String)
    case extractionDeckDigestMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .missingProfileArtifact(let path):
            return "Layout extraction profile artifact is missing: \(path)"
        case .unreadableProfileArtifact(let path, let reason):
            return "Could not read layout extraction profile artifact '\(path)': \(reason)"
        case .invalidProfileArtifact(let path, let reason):
            return "Layout extraction profile artifact '\(path)' is invalid: \(reason)"
        case .unsupportedSchemaVersion(let actual, let supported):
            return "Unsupported layout extraction profile schema version \(actual); expected \(supported)."
        case .processProfileMismatch(let expected, let actual):
            return "Layout extraction profile ID mismatch: expected '\(expected)', found '\(actual)'."
        case .missingExtractionDeck(let path):
            return "Layout extraction deck artifact is missing: \(path)"
        case .unreadableExtractionDeck(let path, let reason):
            return "Could not read layout extraction deck artifact '\(path)': \(reason)"
        case .extractionDeckDigestMismatch(let expected, let actual):
            return "Layout extraction deck digest mismatch: expected '\(expected)', computed '\(actual)'."
        }
    }
}
