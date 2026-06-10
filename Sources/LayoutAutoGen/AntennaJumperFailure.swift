import Foundation
import LayoutCore

/// One gate the jumper inserter could not protect, with the explicit
/// reason. Callers must surface these; the inserter never drops a gate
/// silently.
public struct AntennaJumperFailure: Hashable, Sendable, CustomStringConvertible {
    public enum Reason: Hashable, Sendable {
        /// No via definition has the violating layer as its bottom, so
        /// there is no upper layer to bridge through. Top-layer violations
        /// need an antenna diode or diffusion tie instead of a jumper.
        case noBridgeLayerAbove(LayoutLayerID)
        /// The violating layer or the bridge layer has no rule set, so
        /// landing pads and the split gap cannot be sized.
        case missingLayerRules(LayoutLayerID)
        /// None of the component's editable rectangular wires near the
        /// gate is long enough to host stub, gap, and landing.
        case noSplittableWireNearGate
    }

    public var layer: LayoutLayerID
    public var gatePosition: LayoutPoint
    public var reason: Reason

    public init(layer: LayoutLayerID, gatePosition: LayoutPoint, reason: Reason) {
        self.layer = layer
        self.gatePosition = gatePosition
        self.reason = reason
    }

    public var description: String {
        let location = "gate at (\(gatePosition.x), \(gatePosition.y)) on \(layer.name)"
        switch reason {
        case .noBridgeLayerAbove(let layerID):
            return "\(location): no conductor layer above \(layerID.name) to bridge through; needs an antenna diode or diffusion tie"
        case .missingLayerRules(let layerID):
            return "\(location): missing layer rules for \(layerID.name); cannot size the jumper"
        case .noSplittableWireNearGate:
            return "\(location): no splittable rectangular wire near the gate is long enough for stub, gap, and landing"
        }
    }
}
