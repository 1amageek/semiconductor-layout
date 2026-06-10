import Foundation

public enum AutoGenError: Error, Sendable, LocalizedError {
    case unsupportedDevice(String)
    case missingParameter(device: String, parameter: String)
    case missingLayerRule(String)
    case missingEnclosureRule(outer: String, inner: String)
    case missingContactDefinition(String)
    case placementFailed(String)
    case routingFailed(String)
    case antennaMitigationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice(let device):
            return "Unsupported device type: \(device)"
        case .missingParameter(let device, let parameter):
            return "Device '\(device)' is missing required parameter '\(parameter)'"
        case .missingLayerRule(let layer):
            return "Missing design rules for layer '\(layer)' in technology database"
        case .missingEnclosureRule(let outer, let inner):
            return "Missing enclosure rule from '\(outer)' to '\(inner)' in technology database"
        case .missingContactDefinition(let id):
            return "Missing contact definition '\(id)' in technology database"
        case .placementFailed(let reason):
            return "Placement failed: \(reason)"
        case .routingFailed(let reason):
            return "Routing failed: \(reason)"
        case .antennaMitigationFailed(let reason):
            return "Antenna mitigation failed: \(reason)"
        }
    }
}
