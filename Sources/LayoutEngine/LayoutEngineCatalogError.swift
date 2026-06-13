import Foundation

public enum LayoutEngineCatalogError: LocalizedError, Sendable, Equatable {
    case unknownPlacementEngine(id: String, availableIDs: [String])
    case unknownRoutingEngine(id: String, availableIDs: [String])
    case missingPostRouteVerifier

    public var errorDescription: String? {
        switch self {
        case .unknownPlacementEngine(let id, let availableIDs):
            return "Unknown placement engine '\(id)'. Available placement engines: \(describe(availableIDs))."
        case .unknownRoutingEngine(let id, let availableIDs):
            return "Unknown routing engine '\(id)'. Available routing engines: \(describe(availableIDs))."
        case .missingPostRouteVerifier:
            return "No post-route verifier is registered in the layout engine catalog."
        }
    }

    private func describe(_ ids: [String]) -> String {
        ids.isEmpty ? "none" : ids.sorted().joined(separator: ", ")
    }
}
