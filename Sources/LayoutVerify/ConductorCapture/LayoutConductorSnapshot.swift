import Foundation
import LayoutCore
import LayoutTech
import MaskGeometry

/// Owned native geometry and physical contacts; no RC or qualification claim.
public struct LayoutConductorSnapshot: Sendable, Equatable {
    /// A cell-local net resolved to its owning occurrence through terminal bindings.
    public struct NetReference: Sendable, Equatable, Hashable, Comparable, Codable {
        public let occurrenceIndex: Int
        public let netID: UUID

        public init(occurrenceIndex: Int, netID: UUID) {
            self.occurrenceIndex = occurrenceIndex
            self.netID = netID
        }

        public static func < (first: Self, second: Self) -> Bool {
            first.occurrenceIndex == second.occurrenceIndex
                ? first.netID.isCanonicallyOrderedBefore(second.netID)
                : first.occurrenceIndex < second.occurrenceIndex
        }
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
    /// Coordinate scale of all footprint and pin bands, independently of raw source units.
    public let coordinateUnits: LayoutUnits
    public let conductiveLayers: Set<LayoutLayerID>
    /// Validated cut-to-metal topology used by capture and cross-snapshot queries.
    let adjacentConductorLayersByCut: [LayoutLayerID: Set<LayoutLayerID>]
    let contactTechnology: LayoutTechDatabase
    public let footprints: [Footprint]
    public let contacts: [Contact]
    public let components: [Component]
    public let pins: [Pin]
    public let opens: [Open]
    /// Indices of components claimed by multiple distinct resolved net references.
    public let shortComponentIndices: [Int]

    /// Tests actual integer coverage, after admitting the two captures' topology
    /// and coordinate scales. Callers own their candidate-probe work budget.
    public func hasElectricalContact(
        footprintAt firstIndex: Int,
        with other: LayoutConductorSnapshot,
        footprintAt secondIndex: Int
    ) throws -> Bool {
        guard footprints.indices.contains(firstIndex) else {
            throw LayoutConductorCaptureError.invalidFootprintIndex(firstIndex)
        }
        guard other.footprints.indices.contains(secondIndex) else {
            throw LayoutConductorCaptureError.invalidFootprintIndex(secondIndex)
        }
        guard contactTechnology == other.contactTechnology,
              conductiveLayers == other.conductiveLayers,
              adjacentConductorLayersByCut == other.adjacentConductorLayersByCut else {
            throw LayoutConductorCaptureError.incompatibleContactTopology
        }
        let firstScale = coordinateUnits.scale.databaseUnitsPerMicrometer
        let secondScale = other.coordinateUnits.scale.databaseUnitsPerMicrometer
        let commonScale = max(firstScale, secondScale)
        func multiplier(for scale: Double) throws -> Int64 {
            let ratio = commonScale / scale
            guard let result = Int64(exactly: ratio), result > 0 else {
                throw LayoutConductorCaptureError.incompatibleContactUnits
            }
            // Double division and reverse multiplication can both round a
            // nonintegral ratio to an integer. Compare the exact binary values.
            let shift = commonScale.exponent - scale.exponent
            guard (0...64).contains(shift),
                  let lower = Int128(exactly: scale.significand * 0x1p52),
                  let upper = Int128(exactly: commonScale.significand * 0x1p52) else {
                throw LayoutConductorCaptureError.incompatibleContactUnits
            }
            let product = lower.multipliedReportingOverflow(by: Int128(result))
            // Each normalized significand has at most 53 bits; shifting by at
            // most 64 fits Int128. The multiplication is checked independently.
            guard !product.overflow, upper << shift == product.partialValue else {
                throw LayoutConductorCaptureError.incompatibleContactUnits
            }
            return result
        }
        let firstMultiplier = try multiplier(for: firstScale)
        let secondMultiplier = try multiplier(for: secondScale)
        let first = footprints[firstIndex], second = other.footprints[secondIndex]
        let sameLayer = first.layer == second.layer
        let adjacent = first.isCut && !second.isCut && adjacentConductorLayersByCut[first.layer]?.contains(second.layer) == true
            || second.isCut && !first.isCut && adjacentConductorLayersByCut[second.layer]?.contains(first.layer) == true
        guard sameLayer || adjacent else { return false }
        return try Self.bandsTouch(first.band, multiplier: firstMultiplier,
                                   second.band, multiplier: secondMultiplier, sameLayer: sameLayer)
    }

    /// One predicate owns both full-capture and local-update contact semantics.
    static func bandsTouch(
        _ first: RectilinearBand, multiplier firstMultiplier: Int64 = 1,
        _ second: RectilinearBand, multiplier secondMultiplier: Int64 = 1,
        sameLayer: Bool
    ) throws -> Bool {
        func scaled(_ value: Int32, by multiplier: Int64) throws -> Int64 {
            let result = Int64(value).multipliedReportingOverflow(by: multiplier)
            guard !result.overflow else { throw LayoutConductorCaptureError.incompatibleContactUnits }
            return result.partialValue
        }
        let minX = max(try scaled(first.minX, by: firstMultiplier), try scaled(second.minX, by: secondMultiplier))
        let maxX = min(try scaled(first.maxX, by: firstMultiplier), try scaled(second.maxX, by: secondMultiplier))
        let minY = max(try scaled(first.minY, by: firstMultiplier), try scaled(second.minY, by: secondMultiplier))
        let maxY = min(try scaled(first.maxY, by: firstMultiplier), try scaled(second.maxY, by: secondMultiplier))
        return sameLayer ? (minX < maxX && minY <= maxY || minX <= maxX && minY < maxY)
            : (minX < maxX && minY < maxY)
    }
}
