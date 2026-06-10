import Foundation
import LayoutCore

/// One antenna-mitigation work item: gates on `layer`'s charge-collection
/// component that need the connected metal cut down by a layer jump.
///
/// `shapeIDs` lists the component's shapes on the violating layer (the
/// candidate wires to split); `gates` are the protected gate terminals in
/// the coordinates of the cell being edited. Both come from the antenna
/// violation that motivated the request.
public struct AntennaJumperRequest: Hashable, Sendable {
    public var layer: LayoutLayerID
    public var shapeIDs: [UUID]
    public var gates: [AntennaJumperGate]

    public init(
        layer: LayoutLayerID,
        shapeIDs: [UUID],
        gates: [AntennaJumperGate]
    ) {
        self.layer = layer
        self.shapeIDs = shapeIDs
        self.gates = gates
    }
}
