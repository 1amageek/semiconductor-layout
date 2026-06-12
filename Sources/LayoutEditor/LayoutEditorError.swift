import Foundation

/// Editor-level refusals that have no LayoutCore counterpart.
public enum LayoutEditorError: Error, Sendable {
    /// Entering in-place edit on an arrayed instance is ambiguous about
    /// which occurrence anchors the context — explode the array first.
    case arrayedInstanceEditInPlace(UUID)
    /// The instance transform cannot be inverted (zero magnification),
    /// so pointer coordinates cannot be mapped into the child space.
    case degenerateInstanceTransform(UUID)
    /// Interactive routing verifies against the viewed top context and is
    /// not available while editing in place.
    case routingUnavailableInPlace
    /// The auto-complete search found no clear path inside its window.
    case routeWindowMiss
    /// finish-net was asked for a net that has no remaining open.
    case netAlreadyConnected(UUID)
    /// finish-net found a path but it would create the named violation.
    case finishNetBlocked(String)
    /// finish-net committed, but the post-commit gate (net progress and
    /// DRC cleanliness) failed; the commit was rolled back.
    case finishNetRegressed
    /// A goal command referenced an intent device that is not in the
    /// unplaced list (already realized, or never in the reference).
    case intentDeviceNotFound(String)
}

extension LayoutEditorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .arrayedInstanceEditInPlace(let id):
            return "Cannot edit an arrayed instance in place (explode it first): \(id)"
        case .degenerateInstanceTransform(let id):
            return "Instance transform is not invertible: \(id)"
        case .routingUnavailableInPlace:
            return "Interactive routing is not available while editing in place"
        case .routeWindowMiss:
            return "No clear route exists inside the auto-complete window"
        case .netAlreadyConnected(let id):
            return "Net \(id) has no remaining open to finish"
        case .finishNetBlocked(let reason):
            return "finish-net blocked: \(reason)"
        case .finishNetRegressed:
            return "finish-net result failed its gate and was rolled back"
        case .intentDeviceNotFound(let id):
            return "Intent device not found among unplaced devices: \(id)"
        }
    }
}
