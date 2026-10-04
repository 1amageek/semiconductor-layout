import Foundation
import LayoutCore
import LayoutTech

extension LayoutConnectivityExtractor {
    /// The development connectivity profile explicitly admits every registered
    /// non-cut layer. Cut roles come only from process topology, not display names.
    static func productionConductiveLayers(
        _ tech: LayoutTechDatabase, limits: LayoutConductorCaptureLimits
    ) throws -> Set<LayoutLayerID> {
        guard limits.maximumTechnologyRecords >= 0 else { throw LayoutConductorCaptureError.invalidLimits }
        var remaining = limits.maximumTechnologyRecords
        // Admit input work before constructing role sets, using the capture
        // owner's budget rather than an unbounded preliminary projection.
        for count in [tech.layers.count, tech.vias.count, tech.contacts.count] {
            guard count <= remaining else { throw LayoutConductorCaptureError.limitExceeded(.technologyRecords) }
            remaining -= count
        }
        var cuts: Set<LayoutLayerID> = []
        for via in tech.vias { cuts.insert(via.cutLayer) }
        for contact in tech.contacts { cuts.insert(contact.cutLayer) }
        var layers: Set<LayoutLayerID> = []
        for layer in tech.layers where !cuts.contains(layer.id) { layers.insert(layer.id) }
        guard layers.count <= remaining else { throw LayoutConductorCaptureError.limitExceeded(.technologyRecords) }
        return layers
    }

    static func capturedElements(
        _ snapshot: LayoutConductorSnapshot
    ) throws -> (elements: [ConnectivityElementKey: ConnectivityElement], keys: [ConnectivityElementKey]) {
        let hierarchy = snapshot.hierarchy
        let registered = Set(snapshot.contactTechnology.layers.map(\.id))
        for shape in hierarchy.shapes where !registered.contains(shape.layer) {
            throw LayoutConductorCaptureError.unknownLayer(shape.layer)
        }
        guard let root = hierarchy.occurrences.firstIndex(where: {
            $0.parentIndex == nil && $0.sourceCellID == hierarchy.rootCellID
        }) else { throw LayoutConnectivityExtractionError.targetCellNotFound }
        let occurrence = hierarchy.occurrences[root]
        var shapeIDs: Set<UUID> = [], viaIDs: Set<UUID> = []
        for index in occurrence.shapeRange {
            let id = hierarchy.shapes[index].id
            guard shapeIDs.insert(id).inserted else { throw LayoutConnectivityExtractionError.ambiguousSourceIdentity(id) }
        }
        for index in occurrence.viaRange {
            let id = hierarchy.vias[index].id
            guard viaIDs.insert(id).inserted else { throw LayoutConnectivityExtractionError.ambiguousSourceIdentity(id) }
        }
        let dbu = snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        var elements: [ConnectivityElementKey: ConnectivityElement] = [:]
        var keys: [ConnectivityElementKey] = []
        var bandCounts: [ConnectivityElementKey: Int] = [:]
        elements.reserveCapacity(snapshot.footprints.count)
        keys.reserveCapacity(snapshot.footprints.count)
        for (index, footprint) in snapshot.footprints.enumerated() {
            let sourceKey: ConnectivityElementKey
            let isVia: Bool
            switch footprint.source {
            case .shape(let source):
                sourceKey = .shape(footprint.occurrenceIndex == root ? .top(footprint.sourceID)
                    : .child(source - occurrence.shapeRange.count))
                isVia = false
            case .via(let source):
                sourceKey = .via(footprint.occurrenceIndex == root ? .top(footprint.sourceID)
                    : .child(source - occurrence.viaRange.count))
                isVia = true
            case .pin:
                throw LayoutConductorCaptureError.unsupportedGeometry(footprint.sourceID)
            }
            let bandIndex = bandCounts[sourceKey, default: 0]
            bandCounts[sourceKey] = bandIndex + 1
            let key = sourceKey.band(bandIndex), band = footprint.band
            let bounds = LayoutRect(origin: .init(x: Double(band.minX) / dbu, y: Double(band.minY) / dbu),
                size: .init(width: Double(Int64(band.maxX) - Int64(band.minX)) / dbu,
                            height: Double(Int64(band.maxY) - Int64(band.minY)) / dbu))
            elements[key] = ConnectivityElement(key: key, elementID: footprint.sourceID, isVia: isVia,
                netID: footprint.declaredNet?.netID, geometry: .rect(bounds), layer: footprint.layer,
                viaDefinition: nil, viaCutRects: [], viaContactRectsByLayer: [:], boundingBox: bounds,
                conductorCapture: snapshot, footprintIndex: index, declaredNet: footprint.declaredNet)
            keys.append(key)
        }
        return (elements, keys)
    }

    /// Lowers native contacts and scoped component/pin labels; no source-object
    /// union or second geometry algorithm is involved.
    static func analysis(from snapshot: LayoutConductorSnapshot) throws -> ConnectivityAnalysis {
        let captured = try capturedElements(snapshot)
        let elements = captured.elements, keys = captured.keys
        var netsByNativeComponent: [ConnectivityNet] = []
        for component in snapshot.components {
            var net = net(for: component.footprintIndices.map { keys[$0] }.sorted(), elements: elements)
            net.declaredNets = component.declaredNets
            netsByNativeComponent.append(net)
        }
        let nets = netsByNativeComponent.sorted { $0.memberKeys[0] < $1.memberKeys[0] }
        var result = analysis(nets: nets, elements: elements)
        result.sourceSnapshot = snapshot
        for open in snapshot.opens where !open.unconnectedPinIndices.isEmpty {
            if let index = result.opens.firstIndex(where: { $0.netID == open.net }) {
                result.opens[index].unconnectedPinIndices = open.unconnectedPinIndices
            } else {
                let islands = open.componentIndices.map { index in
                    let net = netsByNativeComponent[index]
                    return ConnectivityIsland(shapeIDs: net.shapeIDs, viaIDs: net.viaIDs,
                        boundingBox: net.boundingBox, memberFootprints: net.memberFootprints, memberKeys: net.memberKeys)
                }
                result.opens.append(ConnectivityOpen(netID: open.net, islands: islands,
                    flylines: flylines(netID: open.net, islands: islands, elements: elements),
                    unconnectedPinIndices: open.unconnectedPinIndices))
            }
        }
        result.opens.sort { $0.netID < $1.netID }
        return result
    }
}
