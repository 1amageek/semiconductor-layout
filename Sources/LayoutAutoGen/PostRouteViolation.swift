import Foundation
import LayoutCore

/// A must-fix violation reported by a post-route verifier.
///
/// Carries only the identity fields a routing repair loop needs: the shape,
/// via, and net IDs of the assembled document, which the loop intersects
/// with the routing result to find the implicated nets. Verifier-specific
/// detail (rule IDs, severities, fix hints) stays behind the verifier.
public struct PostRouteViolation: Hashable, Sendable {
    public var message: String
    public var layer: LayoutLayerID?
    public var region: LayoutRect
    public var shapeIDs: [UUID]
    public var viaIDs: [UUID]
    public var netIDs: [UUID]

    public init(
        message: String,
        layer: LayoutLayerID? = nil,
        region: LayoutRect = .zero,
        shapeIDs: [UUID] = [],
        viaIDs: [UUID] = [],
        netIDs: [UUID] = []
    ) {
        self.message = message
        self.layer = layer
        self.region = region
        self.shapeIDs = shapeIDs
        self.viaIDs = viaIDs
        self.netIDs = netIDs
    }
}
