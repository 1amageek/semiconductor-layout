import Foundation
import LayoutCore
import MaskGeometry

/// Owned native geometry and physical contacts; no RC or qualification claim.
public struct LayoutConductorSnapshot: Sendable, Equatable {
    /// A cell-local net resolved to its owning occurrence through terminal bindings.
    public struct NetReference: Sendable, Equatable, Hashable {
        public let occurrenceIndex: Int
        public let netID: UUID
    }
    public enum Source: Sendable, Equatable, Hashable {
        case shape(Int)
        case via(Int)
        case pin(Int)
    }
    public struct Footprint: Sendable, Equatable {
        public let occurrenceIndex: Int
        public let source: Source
        public let sourceID: UUID
        public let layer: LayoutLayerID
        public let isCut: Bool
        /// Source polygon and band identity within this captured value.
        public let band: RectilinearBand
        public let declaredNet: NetReference?
    }
    public struct Contact: Sendable, Equatable {
        public let firstFootprint: Int
        public let secondFootprint: Int
    }
    public struct Component: Sendable, Equatable {
        public let footprintIndices: [Int]
        public let declaredNets: [NetReference]
        public let pinIndices: [Int]
    }
    public struct Pin: Sendable, Equatable {
        public let occurrenceIndex: Int
        public let sourcePinIndex: Int
        public let declaredNet: NetReference?
        public let bands: [RectilinearBand]
        /// A pin labels each contacted component without conducting between them.
        public let componentIndices: [Int]
    }
    public struct Open: Sendable, Equatable {
        public let net: NetReference
        public let componentIndices: [Int]
        public let unconnectedPinIndices: [Int]
    }

    public let hierarchy: LayoutHierarchySnapshot
    public let conductiveLayers: Set<LayoutLayerID>
    public let footprints: [Footprint]
    public let contacts: [Contact]
    public let components: [Component]
    public let pins: [Pin]
    public let opens: [Open]
    /// Indices of components claimed by multiple distinct resolved net references.
    public let shortComponentIndices: [Int]
}
