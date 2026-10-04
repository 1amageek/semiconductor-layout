import Foundation
import LayoutCore

extension LayoutDRCService {
    /// Converts actual native electrical facts into source-linked violations.
    /// UUID fields are highlights; references retain the owning occurrence.
    func electricalViolations(snapshot: LayoutConductorSnapshot) -> [LayoutViolation] {
        let dbu = snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        func region(_ footprints: [Int], _ pins: [Int]) -> LayoutRect {
            var result: LayoutRect?
            for index in footprints {
                let band = snapshot.footprints[index].band
                let bounds = LayoutRect(origin: .init(x: Double(band.minX) / dbu, y: Double(band.minY) / dbu),
                    size: .init(width: Double(Int64(band.maxX) - Int64(band.minX)) / dbu,
                        height: Double(Int64(band.maxY) - Int64(band.minY)) / dbu))
                result = result.map { $0.union(bounds) } ?? bounds
            }
            for index in pins {
                let bounds = LayoutGeometryAnalysis.boundingBox(for: snapshot.hierarchy.pinGeometries[index])
                result = result.map { $0.union(bounds) } ?? bounds
            }
            return result ?? .zero
        }
        func highlights(_ footprints: [Int]) -> (shapes: [UUID], vias: [UUID]) {
            var shapes = Set<UUID>(), vias = Set<UUID>()
            for index in footprints {
                let footprint = snapshot.footprints[index]
                switch footprint.source {
                case .shape: shapes.insert(footprint.sourceID)
                case .via: vias.insert(footprint.sourceID)
                case .pin: break
                }
            }
            return (shapes.sorted { $0.uuidString < $1.uuidString }, vias.sorted { $0.uuidString < $1.uuidString })
        }
        var result: [LayoutViolation] = []
        for index in snapshot.shortComponentIndices {
            let component = snapshot.components[index]
            let ids = highlights(component.footprintIndices)
            let pins = component.pinIndices.map { snapshot.pins[$0].sourcePinIndex }.sorted()
            result.append(LayoutViolation(kind: .overlapShort, ruleID: "connectivity.short.nativeComponent",
                message: "Short between scoped nets in one physical component", region: region(component.footprintIndices, pins),
                shapeIDs: ids.shapes, viaIDs: ids.vias, pinIDs: pins.map { snapshot.hierarchy.pins[$0].id },
                netIDs: Array(Set(component.declaredNets.map(\.netID))).sorted { $0.uuidString < $1.uuidString },
                netReferences: component.declaredNets, sourcePinIndices: pins,
                suggestedFix: "Separate the actual connected geometry or correct the explicit terminal bindings."))
        }
        for open in snapshot.opens {
            let footprints = open.componentIndices.flatMap { snapshot.components[$0].footprintIndices }
            let ids = highlights(footprints)
            let pins = open.unconnectedPinIndices.map { snapshot.pins[$0].sourcePinIndex }.sorted()
            result.append(LayoutViolation(kind: .disconnectedOpen, ruleID: "connectivity.open.nativeNet",
                message: "Scoped net has \(open.componentIndices.count) islands and \(pins.count) unconnected pins",
                region: region(footprints, pins), shapeIDs: ids.shapes, viaIDs: ids.vias,
                pinIDs: pins.map { snapshot.hierarchy.pins[$0].id }, netIDs: [open.net.netID],
                netReferences: [open.net], sourcePinIndices: pins,
                suggestedFix: "Connect the actual conductor islands and isolated pin areas."))
        }
        return result
    }
}
