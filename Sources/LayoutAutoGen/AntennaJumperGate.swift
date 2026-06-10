import Foundation
import LayoutCore

/// A protected gate terminal: the pin's center and footprint in the
/// coordinates of the cell being edited.
///
/// The footprint matters because the split must land beyond it — a cut
/// straddled by the gate pin would leave the pin touching both pieces and
/// silently reconnect the charge-collection path it was meant to break.
public struct AntennaJumperGate: Hashable, Sendable {
    public var position: LayoutPoint
    public var size: LayoutSize

    public init(position: LayoutPoint, size: LayoutSize) {
        self.position = position
        self.size = size
    }
}
