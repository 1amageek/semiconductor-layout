import Foundation

public enum SDLNetAnnotationError: Error, Equatable, Sendable, LocalizedError {
    case conflictingComponentNames([String])
    case ambiguousPin(String)
    case unavailableTerminalBinding(pin: String, instancePath: [UUID])
    case conflictingTerminalBinding(instance: UUID, pin: String)
    case unmatchedLabels([String])
    case pointProbeLimitExceeded
    case invalidCapturedSource

    public var errorDescription: String? {
        switch self {
        case .conflictingComponentNames(let names):
            return "Annotation requested different names on one electrical component: \(names.joined(separator: ", "))"
        case .ambiguousPin(let name):
            return "Annotation cannot bind pin '\(name)' to inconsistent or unnamed contacted components."
        case .unavailableTerminalBinding(let pin, let path):
            return "Annotation has no canonical terminal binding for pin '\(pin)' at instance path \(path)."
        case .conflictingTerminalBinding(let instance, let pin):
            return "Annotation requests incompatible occurrence bindings for instance \(instance), pin '\(pin)'."
        case .unmatchedLabels(let names):
            return "Annotation could not resolve requested labels: \(names.joined(separator: ", "))"
        case .pointProbeLimitExceeded:
            return "Annotation native point probes exceed the caller's admission ceiling."
        case .invalidCapturedSource:
            return "Annotation capture does not identify the canonical edit target."
        }
    }
}
