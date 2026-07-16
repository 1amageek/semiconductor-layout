import Foundation

public enum LayoutPreviewResourceError: Error, Equatable, LocalizedError, Sendable {
    case resourceUnavailable(name: String)
    case technologySidecarUnavailable(name: String)
    case technologyLoadFailed(description: String)
    case layoutReadFailed(description: String)
    case layoutImportFailed(description: String)

    public var errorDescription: String? {
        switch self {
        case let .resourceUnavailable(name):
            return "The packaged layout preview resource '\(name)' is unavailable."
        case let .technologySidecarUnavailable(name):
            return "The packaged layout preview resource '\(name)' has no technology sidecar."
        case let .technologyLoadFailed(description):
            return "The packaged layout preview technology could not be loaded: \(description)"
        case let .layoutReadFailed(description):
            return "The packaged layout preview artifact could not be read: \(description)"
        case let .layoutImportFailed(description):
            return "The packaged layout preview artifact could not be imported: \(description)"
        }
    }
}
