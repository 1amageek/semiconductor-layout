import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

/// Prepares finite-resistance bodies without changing their physical source geometry.
enum PolyResistorConductorPreparation {
    static func apply(hierarchy: LayoutHierarchySnapshot, tech: LayoutTechDatabase,
        polyLayer: LayoutLayerID, bodyMarkerLayer: LayoutLayerID,
        preparation: DeviceExtractor.ConductorPreparation, limits: LayoutConductorCaptureLimits,
        remainingProbes: Int, isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> DeviceExtractor.ConductorPreparation {
        typealias Failure = LayoutConductorCaptureError
        let known = Set(tech.layers.map(\.id))
        let cuts = Set(tech.vias.map(\.cutLayer) + tech.contacts.map(\.cutLayer))
        guard polyLayer != bodyMarkerLayer, known.contains(polyLayer), known.contains(bodyMarkerLayer),
              !cuts.contains(polyLayer), !cuts.contains(bodyMarkerLayer),
              preparation.layers.contains(polyLayer), !preparation.layers.contains(bodyMarkerLayer),
              remainingProbes >= 0 else { throw Failure.unsupportedDevicePreparation }
        guard limits.maximumFootprints >= 0, limits.decomposition.maximumInputEntries >= 0 else { throw Failure.invalidLimits }
        let dbu = try LayoutConnectivityExtractor.captureCoordinateUnits(hierarchy: hierarchy,
            conductiveLayers: preparation.layers, cutLayers: cuts,
            isCancelled: isCancelled).scale.databaseUnitsPerMicrometer
        func integer(_ value: Double, id: UUID) throws -> Int32 {
            try LayoutConnectivityExtractor.integerCoordinate(value, databaseUnitsPerMicrometer: dbu, sourceID: id)
        }
        func rectangle(_ shape: LayoutShape) throws -> IRBoundary {
            let points: [IRPoint]
            switch shape.geometry {
            case .rect(let rect):
                let x = try integer(rect.origin.x, id: shape.id), y = try integer(rect.origin.y, id: shape.id)
                let w = try integer(rect.size.width, id: shape.id), h = try integer(rect.size.height, id: shape.id)
                let (endX, ox) = x.addingReportingOverflow(w), (endY, oy) = y.addingReportingOverflow(h)
                guard w > 0, h > 0, !ox, !oy else { throw Failure.invalidGridGeometry(shape.id) }
                points = [.init(x: x, y: y), .init(x: endX, y: y), .init(x: endX, y: endY), .init(x: x, y: endY)]
            case .polygon(let polygon):
                guard polygon.points.count == 4 || (polygon.points.count == 5 && polygon.points.first == polygon.points.last) else {
                    throw Failure.unsupportedDevicePreparation
                }
                points = try polygon.points.prefix(4).map { .init(x: try integer($0.x, id: shape.id), y: try integer($0.y, id: shape.id)) }
            case .path: throw Failure.unsupportedDevicePreparation
            }
            let xs = Set(points.map(\.x)), ys = Set(points.map(\.y))
            guard xs.count == 2, ys.count == 2, Set(points).count == 4,
                  points.indices.allSatisfy({ index in
                      let next = points[(index + 1) % 4]
                      return (points[index].x == next.x) != (points[index].y == next.y)
                  }) else { throw Failure.unsupportedDevicePreparation }
            return IRBoundary(layer: 0, datatype: 0, points: points)
        }
        var replacements = preparation.replacements
        var probes = remainingProbes, preparedCount = replacements.values.reduce(0) { $0 + $1.count }
        for occurrence in hierarchy.occurrences {
            if isCancelled() { throw Failure.cancelled }
            var polys: [(index: Int, region: Region)] = [], markers: [(index: Int, region: Region)] = []
            for index in occurrence.shapeRange {
                let shape = hierarchy.shapes[index]
                if shape.layer == polyLayer { polys.append((index, Region(polygons: [try rectangle(shape)]))) }
                if shape.layer == bodyMarkerLayer { markers.append((index, Region(polygons: [try rectangle(shape)]))) }
            }
            var usedPoly = Set<Int>()
            for marker in markers {
                var matched: (index: Int, region: Region)?
                guard let body = marker.region.boundingBox else { throw Failure.unsupportedDevicePreparation }
                for poly in polys {
                    if isCancelled() { throw Failure.cancelled }
                    guard probes > 0 else { throw Failure.limitExceeded(.contactProbes) }
                    probes -= 1
                    guard let bounds = poly.region.boundingBox else { throw Failure.unsupportedDevicePreparation }
                    guard body.minX < bounds.maxX, body.maxX > bounds.minX,
                          body.minY < bounds.maxY, body.maxY > bounds.minY else { continue }
                    guard matched == nil else { throw Failure.unsupportedDevicePreparation }
                    matched = poly
                }
                guard let poly = matched, usedPoly.insert(poly.index).inserted,
                      replacements[poly.index] == nil else { throw Failure.unsupportedDevicePreparation }
                guard let bounds = poly.region.boundingBox else { throw Failure.unsupportedDevicePreparation }
                let horizontal = body.minY <= bounds.minY && body.maxY >= bounds.maxY
                    && body.minX > bounds.minX && body.maxX < bounds.maxX
                let vertical = body.minX <= bounds.minX && body.maxX >= bounds.maxX
                    && body.minY > bounds.minY && body.maxY < bounds.maxY
                guard horizontal != vertical else { throw Failure.unsupportedDevicePreparation }
                // The existing integer geometry owner retains actual terminal coverage.
                guard limits.decomposition.maximumInputEntries >= 10 else {
                    throw Failure.decompositionFailed(.limitExceeded(.inputEntries))
                }
                let retained = try poly.region.subtracting(marker.region)
                guard retained.polygons.count == 2 else { throw Failure.unsupportedDevicePreparation }
                guard limits.maximumFootprints >= 2, preparedCount <= limits.maximumFootprints - 2 else {
                    throw Failure.limitExceeded(.footprints)
                }
                preparedCount += 2
                replacements[poly.index] = retained.polygons.map { polygon in
                    .polygon(.init(points: polygon.points.map { .init(x: Double($0.x) / dbu, y: Double($0.y) / dbu) }))
                }
            }
        }
        return .init(layers: preparation.layers, replacements: replacements, slabs: preparation.slabs)
    }
}
