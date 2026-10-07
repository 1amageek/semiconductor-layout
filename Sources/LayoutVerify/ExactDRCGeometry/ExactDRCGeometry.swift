import Foundation
import LayoutCore
import LayoutIR
import MaskGeometry

/// Immutable coverage indexed by actual flattened entries, never by source UUID alone.
struct ExactDRCGeometry: Sendable {
    struct Entry: Sendable {
        let shape: LayoutShape
        let flattenedIndex: Int
        let occurrenceIndex: Int
        let region: Region
    }

    let coordinateUnits: LayoutUnits
    let entries: [Entry]
    private let coverage: [LayoutGeometry: Region]
    private let sourcePins: [LayoutPin]
    private let sourceVias: [LayoutVia]
    private let pinCoverage: [Int: Region]
    private let viaCoverage: [Int: [LayoutLayerID: Region]]

    init(snapshot: LayoutConductorSnapshot, limits: LayoutConductorCaptureLimits,
         unionLimits: RectilinearUnionLimits?, isCancelled: () -> Bool) throws {
        coordinateUnits = snapshot.coordinateUnits
        let dbu = coordinateUnits.scale.databaseUnitsPerMicrometer
        let policy = limits.decomposition
        var budget = try RectilinearUnionBudget(limits: unionLimits ?? .init(
            maximumInputEntries: policy.maximumInputEntries,
            maximumEdgeProbes: policy.maximumEdgeProbes,
            maximumIntermediateBands: policy.maximumOutputBands,
            maximumSweepWork: policy.maximumEdgeProbes,
            maximumOutputBands: policy.maximumOutputBands))
        guard limits.maximumFootprints >= 0 else { throw LayoutConductorCaptureError.invalidLimits }
        var prepared: [Entry] = []
        var regions: [LayoutGeometry: Region] = [:]
        var generatedPieces = 0
        var generatedInputEntries = 0
        for (occurrenceIndex, occurrence) in snapshot.hierarchy.occurrences.enumerated() {
            for index in occurrence.shapeRange {
                if isCancelled() { throw ExactDRCGeometryError.cancelled }
                let shape = snapshot.hierarchy.shapes[index]
                let region: Region
                switch shape.geometry {
                case .path(let path):
                    var pieces: [IRBoundary] = []
                    var pendingInputEntries = 0
                    do {
                        try RectilinearPathProjection.emit(path, coordinate: {
                            try Self.coordinate($0, dbu: dbu, sourceID: shape.id)
                        }, isCancelled: isCancelled) { minX, minY, maxX, maxY in
                            guard generatedPieces < limits.maximumFootprints else {
                                throw ExactDRCGeometryError.generatedPieceLimit
                            }
                            // Five closed vertices plus the decomposition's polygon entry.
                            guard policy.maximumInputEntries >= 6,
                                  generatedInputEntries <= policy.maximumInputEntries - 6,
                                  budget.remainingInputEntries >= 6,
                                  pendingInputEntries <= budget.remainingInputEntries - 6 else {
                                throw RectilinearDecompositionError.limitExceeded(.inputEntries)
                            }
                            generatedInputEntries += 6
                            pendingInputEntries += 6
                            generatedPieces += 1
                            pieces.append(try Self.rectangle(minX: minX, minY: minY,
                                maxX: maxX, maxY: maxY, sourceID: shape.id))
                        }
                    } catch let error as RectilinearPathProjectionError {
                        switch error {
                        case .invalidGridGeometry: throw ExactDRCGeometryError.invalidGridGeometry(sourceID: shape.id)
                        case .unsupportedGeometry: throw ExactDRCGeometryError.unsupportedGeometry(sourceID: shape.id)
                        case .cancelled: throw ExactDRCGeometryError.cancelled
                        }
                    }
                    let bands = try Region(polygons: pieces).rectilinearUnionBands(
                        toPolygonIndex: index, budget: &budget, isCancelled: isCancelled)
                    var boundaries: [IRBoundary] = []
                    var area: Int64 = 0
                    for band in bands {
                        if isCancelled() { throw ExactDRCGeometryError.cancelled }
                        let boundary = try Self.rectangle(minX: band.minX, minY: band.minY,
                            maxX: band.maxX, maxY: band.maxY, sourceID: shape.id)
                        let (sum, overflow) = area.addingReportingOverflow(PolygonGeometry.area(boundary.points))
                        guard !overflow else { throw ExactDRCGeometryError.invalidGridGeometry(sourceID: shape.id) }
                        area = sum
                        boundaries.append(boundary)
                    }
                    region = Region(polygons: boundaries)
                case .rect, .polygon:
                    region = try Self.primitiveRegion(shape.geometry, dbu: dbu,
                        sourceID: shape.id, isCancelled: isCancelled)
                }
                prepared.append(Entry(shape: shape, flattenedIndex: index,
                    occurrenceIndex: occurrenceIndex, region: region))
                regions[shape.geometry] = region
            }
        }
        if isCancelled() { throw ExactDRCGeometryError.cancelled }
        var pinRegions: [Int: Region] = [:]
        for pin in snapshot.pins {
            if isCancelled() { throw ExactDRCGeometryError.cancelled }
            guard snapshot.hierarchy.pins.indices.contains(pin.sourcePinIndex),
                  snapshot.hierarchy.occurrences.indices.contains(pin.occurrenceIndex),
                  snapshot.hierarchy.occurrences[pin.occurrenceIndex].pinRange.contains(pin.sourcePinIndex),
                  pinRegions[pin.sourcePinIndex] == nil, !pin.bands.isEmpty else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
            }
            let source = snapshot.hierarchy.pins[pin.sourcePinIndex]
            var boundaries: [IRBoundary] = []
            for band in pin.bands {
                if isCancelled() { throw ExactDRCGeometryError.cancelled }
                boundaries.append(try Self.rectangle(minX: band.minX, minY: band.minY,
                    maxX: band.maxX, maxY: band.maxY, sourceID: source.id))
            }
            pinRegions[pin.sourcePinIndex] = Region(polygons: boundaries)
        }
        var viaBoundaries: [Int: [LayoutLayerID: [IRBoundary]]] = [:]
        for footprint in snapshot.footprints {
            if isCancelled() { throw ExactDRCGeometryError.cancelled }
            guard case .via(let index) = footprint.source else { continue }
            guard snapshot.hierarchy.vias.indices.contains(index),
                  snapshot.hierarchy.occurrences.indices.contains(footprint.occurrenceIndex),
                  snapshot.hierarchy.occurrences[footprint.occurrenceIndex].viaRange.contains(index),
                  snapshot.hierarchy.vias[index].id == footprint.sourceID else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: footprint.sourceID)
            }
            let band = footprint.band
            viaBoundaries[index, default: [:]][footprint.layer, default: []].append(
                try Self.rectangle(minX: band.minX, minY: band.minY,
                    maxX: band.maxX, maxY: band.maxY, sourceID: footprint.sourceID))
        }
        var viaRegions: [Int: [LayoutLayerID: Region]] = [:]
        for (index, layers) in viaBoundaries {
            if isCancelled() { throw ExactDRCGeometryError.cancelled }
            viaRegions[index] = layers.mapValues { Region(polygons: $0) }
        }
        entries = prepared
        coverage = regions
        sourcePins = snapshot.hierarchy.pins
        sourceVias = snapshot.hierarchy.vias
        pinCoverage = pinRegions
        viaCoverage = viaRegions
    }

    func shapeRegion(at index: Int, source: LayoutShape) throws -> Region {
        guard entries.indices.contains(index), entries[index].flattenedIndex == index,
              entries[index].shape == source else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: source.id)
        }
        return entries[index].region
    }

    func pinRegion(at index: Int, source: LayoutPin) throws -> Region {
        guard sourcePins.indices.contains(index), sourcePins[index] == source,
              let region = pinCoverage[index] else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: source.id)
        }
        return region
    }

    func viaRegions(at index: Int, source: LayoutVia) throws -> [LayoutLayerID: Region] {
        guard sourceVias.indices.contains(index), sourceVias[index] == source,
              let regions = viaCoverage[index], !regions.isEmpty else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: source.id)
        }
        return regions
    }

    func region(for geometry: LayoutGeometry) throws -> Region {
        if let region = coverage[geometry] { return region }
        return try Self.primitiveRegion(geometry, dbu: coordinateUnits.scale.databaseUnitsPerMicrometer)
    }

    static func coordinate(_ value: Double, dbu: Double, sourceID: UUID? = nil) throws -> Int32 {
        let scaled = value * dbu
        let integer = scaled.rounded()
        guard value.isFinite, dbu.isFinite, dbu > 0, scaled.isFinite,
              abs(scaled - integer) <= scaled.ulp * 4,
              let result = Int32(exactly: integer) else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
        }
        return result
    }

    static func primitiveRegion(_ geometry: LayoutGeometry, dbu: Double,
                                sourceID: UUID? = nil, isCancelled: () -> Bool = { false }) throws -> Region {
        if isCancelled() { throw ExactDRCGeometryError.cancelled }
        switch geometry {
        case .rect(let rect):
            return try Region(polygons: [rectangle(
                minX: coordinate(rect.minX, dbu: dbu, sourceID: sourceID),
                minY: coordinate(rect.minY, dbu: dbu, sourceID: sourceID),
                maxX: coordinate(rect.maxX, dbu: dbu, sourceID: sourceID),
                maxY: coordinate(rect.maxY, dbu: dbu, sourceID: sourceID), sourceID: sourceID)])
        case .polygon(let polygon):
            guard polygon.points.count >= 3 else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
            }
            var points = try polygon.points.map {
                if isCancelled() { throw ExactDRCGeometryError.cancelled }
                return try IRPoint(x: coordinate($0.x, dbu: dbu, sourceID: sourceID),
                            y: coordinate($0.y, dbu: dbu, sourceID: sourceID))
            }
            if points.first != points.last { points.append(points[0]) }
            guard PolygonGeometry.isManhattan(points) else {
                if let sourceID { throw ExactDRCGeometryError.unsupportedGeometry(sourceID: sourceID) }
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
            }
            try validateArea(points, sourceID: sourceID)
            return Region(polygons: [IRBoundary(layer: 0, datatype: 0, points: points)])
        case .path:
            // Every source PATH must have spent the invocation's aggregate projection budget.
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
        }
    }

    private static func rectangle(minX: Int32, minY: Int32, maxX: Int32, maxY: Int32,
                                  sourceID: UUID?) throws -> IRBoundary {
        guard minX < maxX, minY < maxY else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
        }
        let points = [IRPoint(x: minX, y: minY), IRPoint(x: maxX, y: minY),
                      IRPoint(x: maxX, y: maxY), IRPoint(x: minX, y: maxY), IRPoint(x: minX, y: minY)]
        try validateArea(points, sourceID: sourceID)
        return IRBoundary(layer: 0, datatype: 0, points: points)
    }

    private static func validateArea(_ points: [IRPoint], sourceID: UUID?) throws {
        var twiceArea: Int64 = 0
        for index in 1..<points.count {
            let first = points[index - 1], second = points[index]
            let (cross, crossOverflow) = (Int64(first.x) * Int64(second.y))
                .subtractingReportingOverflow(Int64(second.x) * Int64(first.y))
            let (sum, sumOverflow) = twiceArea.addingReportingOverflow(cross)
            guard !crossOverflow, !sumOverflow else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
            }
            twiceArea = sum
        }
        guard twiceArea != 0, twiceArea != Int64.min else {
            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
        }
    }
}
