import Foundation
import LayoutCore
import MaskGeometry

extension LayoutConnectivityExtractor {
    /// Composes one complete current native value from verified owned bands
    /// and the live consumer's maintained contact partition. No geometry is
    /// reconstructed from display boxes and no second contact graph is built.
    static func composeConductors(
        hierarchy: LayoutHierarchySnapshot, template: LayoutConductorSnapshot,
        replacement: LayoutConductorSnapshot, replacementSources: Set<ConnectivityElementKey>,
        elements: [ConnectivityElementKey: ConnectivityElement],
        adjacency: [ConnectivityElementKey: Set<ConnectivityElementKey>],
        componentMembers: [[ConnectivityElementKey]], pinContacts: [Int: Set<ConnectivityElementKey>],
        limits: LayoutConductorCaptureLimits
    ) throws -> LayoutConductorSnapshot {
        typealias Snapshot = LayoutConductorSnapshot
        func checkCancellation() throws { if Task.isCancelled { throw LayoutConductorCaptureError.cancelled } }
        guard elements.count <= limits.maximumFootprints else { throw LayoutConductorCaptureError.limitExceeded(.footprints) }
        guard hierarchy.documentID == template.hierarchy.documentID, hierarchy.units == template.hierarchy.units,
              hierarchy.rootCellID == template.hierarchy.rootCellID,
              hierarchy.pins == template.hierarchy.pins, hierarchy.pinGeometries == template.hierarchy.pinGeometries,
              hierarchy.occurrences.count == template.hierarchy.occurrences.count else {
            throw LayoutConductorCaptureError.invalidComposition
        }
        for (current, previous) in zip(hierarchy.occurrences, template.hierarchy.occurrences) {
            try checkCancellation()
            guard current.sourceCellID == previous.sourceCellID, current.parentIndex == previous.parentIndex,
                  current.path == previous.path, current.transforms == previous.transforms,
                  current.terminalNetIDs == previous.terminalNetIDs, current.pinRange == previous.pinRange else {
                throw LayoutConductorCaptureError.invalidComposition
            }
        }
        guard let root = hierarchy.occurrences.firstIndex(where: {
            $0.parentIndex == nil && $0.sourceCellID == hierarchy.rootCellID
        }) else { throw LayoutConductorCaptureError.invalidComposition }
        let rootOccurrence = hierarchy.occurrences[root]
        let units = try captureCoordinateUnits(hierarchy: hierarchy,
            conductiveLayers: template.conductiveLayers, cutLayers: Set(template.adjacentConductorLayersByCut.keys))
        guard replacement.electricalContext == template.electricalContext, replacement.hierarchy == hierarchy, replacement.coordinateUnits == units,
              replacement.contactTechnology == template.contactTechnology,
              replacement.conductiveLayers == template.conductiveLayers,
              replacement.adjacentConductorLayersByCut == template.adjacentConductorLayersByCut else {
            throw LayoutConductorCaptureError.incompatibleContactTopology
        }
        func polygonsBySource(_ capture: Snapshot) -> [Snapshot.Source: [Int]] {
            var result: [Snapshot.Source: [Int]] = [:]
            for index in capture.polygonSources.indices { result[capture.polygonSources[index], default: []].append(index) }
            return result
        }
        let templatePolygons = polygonsBySource(template), replacementPolygons = polygonsBySource(replacement)
        var elementsBySource: [ConnectivityElementKey: [ConnectivityElement]] = [:]
        for element in elements.values {
            try checkCancellation()
            elementsBySource[element.key.sourceKey, default: []].append(element)
        }
        var footprints: [Snapshot.Footprint] = [], polygonSources: [Snapshot.Source] = []
        var indexByKey: [ConnectivityElementKey: Int] = [:]
        var relocatedPins: [Snapshot.Pin] = []
        let pinsBySource = Dictionary(uniqueKeysWithValues: template.pins.map { ($0.sourcePinIndex, $0) })
        func relocate(_ band: RectilinearBand, from capture: Snapshot, polygonIndex: Int, sourceID: UUID) throws -> RectilinearBand {
            let (numerator, denominator) = try capture.coordinateMultipliers(with: units)
            do { return try band.relocated(toPolygonIndex: polygonIndex,
                coordinateNumerator: numerator, coordinateDenominator: denominator) }
            catch let error as RectilinearDecompositionError {
                if error == .inexactRelocationCoordinate { throw LayoutConductorCaptureError.invalidGridGeometry(sourceID) }
                throw LayoutConductorCaptureError.decompositionFailed(error)
            }
        }
        func appendSource(_ source: Snapshot.Source, key: ConnectivityElementKey, sourceID: UUID, occurrence: Int) throws {
            guard let sourceElements = elementsBySource.removeValue(forKey: key) else {
                throw LayoutConductorCaptureError.invalidComposition
            }
            var polygonIndexByOriginal: [Int: Int] = [:]
            // Every piece of one source must share one owned capture. Its band
            // ordinals retain that capture's polygon/scanline emission order.
            let ordered = sourceElements.sorted { $0.key < $1.key }
            let isReplacement = replacementSources.contains(key)
            let owner = isReplacement ? replacement : template
            guard let firstIndex = ordered.first?.footprintIndex, owner.footprints.indices.contains(firstIndex) else {
                throw LayoutConductorCaptureError.invalidComposition
            }
            let originalSource = owner.footprints[firstIndex].source
            for index in (isReplacement ? replacementPolygons : templatePolygons)[originalSource, default: []] {
                polygonIndexByOriginal[index] = polygonSources.count
                polygonSources.append(source)
            }
            for (bandIndex, element) in ordered.enumerated() {
                try checkCancellation()
                guard element.key == key.band(bandIndex),
                      let index = element.footprintIndex, owner.footprints.indices.contains(index) else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                let old = owner.footprints[index]
                guard old.sourceID == sourceID, old.source == originalSource,
                      old.occurrenceIndex == occurrence,
                      let polygon = polygonIndexByOriginal[old.band.polygonIndex] else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                indexByKey[element.key] = footprints.count
                footprints.append(Snapshot.Footprint(occurrenceIndex: occurrence, source: source,
                    sourceID: sourceID, layer: old.layer, isCut: old.isCut,
                    band: try relocate(old.band, from: owner, polygonIndex: polygon, sourceID: sourceID),
                    declaredNet: old.declaredNet))
            }
        }
        let registeredLayers = Set(template.contactTechnology.layers.map(\.id))
        for (occurrenceIndex, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            for index in occurrence.shapeRange {
                let shape = hierarchy.shapes[index]
                guard registeredLayers.contains(shape.layer) else {
                    throw LayoutConductorCaptureError.unknownLayer(shape.layer)
                }
                guard template.conductiveLayers.contains(shape.layer) || template.adjacentConductorLayersByCut[shape.layer] != nil else { continue }
                try appendSource(.shape(index), key: .shape(occurrenceIndex == root ? .top(shape.id)
                    : .child(index - rootOccurrence.shapeRange.count)), sourceID: shape.id, occurrence: occurrenceIndex)
            }
            for index in occurrence.viaRange {
                let via = hierarchy.vias[index]
                try appendSource(.via(index), key: .via(occurrenceIndex == root ? .top(via.id)
                    : .child(index - rootOccurrence.viaRange.count)), sourceID: via.id, occurrence: occurrenceIndex)
            }
            for index in occurrence.pinRange {
                guard template.conductiveLayers.contains(hierarchy.pins[index].layer) else { continue }
                guard let pin = pinsBySource[index], pin.occurrenceIndex == occurrenceIndex else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                var polygonIndexByOriginal: [Int: Int] = [:]
                for polygon in templatePolygons[.pin(index), default: []] {
                    polygonIndexByOriginal[polygon] = polygonSources.count
                    polygonSources.append(.pin(index))
                }
                let bands = try pin.bands.map { band -> RectilinearBand in
                    guard let polygon = polygonIndexByOriginal[band.polygonIndex] else {
                        throw LayoutConductorCaptureError.invalidComposition
                    }
                    return try relocate(band, from: template, polygonIndex: polygon, sourceID: hierarchy.pins[index].id)
                }
                relocatedPins.append(Snapshot.Pin(occurrenceIndex: occurrenceIndex, sourcePinIndex: index,
                    declaredNet: pin.declaredNet, bands: bands, footprintIndices: [], componentIndices: []))
            }
        }
        guard elementsBySource.isEmpty, footprints.count == elements.count else {
            throw LayoutConductorCaptureError.invalidComposition
        }
        var contacts: [Snapshot.Contact] = []
        for (key, neighbours) in adjacency {
            try checkCancellation()
            guard let first = indexByKey[key] else { throw LayoutConductorCaptureError.invalidComposition }
            for neighbour in neighbours {
                guard let second = indexByKey[neighbour], adjacency[neighbour]?.contains(key) == true else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                if first < second {
                    guard contacts.count < limits.maximumContactProbes else { throw LayoutConductorCaptureError.limitExceeded(.contactProbes) }
                    contacts.append(Snapshot.Contact(firstFootprint: first, secondFootprint: second))
                }
            }
        }
        contacts.sort { ($0.firstFootprint, $0.secondFootprint) < ($1.firstFootprint, $1.secondFootprint) }
        let groups = try componentMembers.map { members in
            try checkCancellation()
            return try members.map { key in
                guard let index = indexByKey[key] else { throw LayoutConductorCaptureError.invalidComposition }
                return index
            }.sorted()
        }.sorted { ($0.first ?? -1) < ($1.first ?? -1) }
        var componentByFootprint: [Int: Int] = [:]
        for (component, members) in groups.enumerated() {
            guard !members.isEmpty else { throw LayoutConductorCaptureError.invalidComposition }
            for member in members {
                guard componentByFootprint.updateValue(component, forKey: member) == nil else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
            }
        }
        guard componentByFootprint.count == footprints.count else { throw LayoutConductorCaptureError.invalidComposition }
        for contact in contacts where componentByFootprint[contact.firstFootprint] != componentByFootprint[contact.secondFootprint] {
            throw LayoutConductorCaptureError.invalidComposition
        }
        for index in relocatedPins.indices {
            try checkCancellation()
            let pin = relocatedPins[index]
            let members = pinContacts[pin.sourcePinIndex, default: []]
            let components = try Set(members.map { key in
                guard let footprint = indexByKey[key], let component = componentByFootprint[footprint] else {
                    throw LayoutConductorCaptureError.invalidComposition
                }
                return component
            }).sorted()
            let footprintIndices = try members.map { key in
                guard let index = indexByKey[key] else { throw LayoutConductorCaptureError.invalidComposition }
                return index
            }.sorted()
            relocatedPins[index] = Snapshot.Pin(occurrenceIndex: pin.occurrenceIndex, sourcePinIndex: pin.sourcePinIndex,
                declaredNet: pin.declaredNet, bands: pin.bands, footprintIndices: footprintIndices, componentIndices: components)
        }
        return try finishCapturedSnapshot(hierarchy: hierarchy, coordinateUnits: units,
            conductiveLayers: template.conductiveLayers, adjacency: template.adjacentConductorLayersByCut,
            tech: template.contactTechnology, footprints: footprints, polygonSources: polygonSources,
            contacts: contacts, groups: groups, pins: relocatedPins, sourceNets: try resolvedSourceNets(hierarchy),
            electricalContext: template.electricalContext, preparedShapeGeometry: replacement.preparedShapeGeometry)
    }
}
