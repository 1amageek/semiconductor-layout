import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutConnectivityExtractor {
    /// Captures exact rectilinear physical contacts without flylines or RC estimates.
    public func captureConductors(
        document: LayoutDocument, tech: LayoutTechDatabase,
        conductiveLayers: Set<LayoutLayerID>, cellID: UUID? = nil,
        limits: LayoutConductorCaptureLimits = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> LayoutConductorSnapshot {
        try captureNativeConductors(document: document, tech: tech, conductiveLayers: conductiveLayers,
            cellID: cellID, limits: limits, isCancelled: isCancelled).snapshot
    }

    /// Internal preparation retains the full profile and hierarchy while
    /// decomposing only the selected source geometry. It is never published
    /// as a complete production analysis before current-generation composition.
    func captureNativeConductors(
        document: LayoutDocument, tech: LayoutTechDatabase,
        conductiveLayers: Set<LayoutLayerID>, cellID: UUID? = nil,
        limits: LayoutConductorCaptureLimits = .default,
        hierarchy suppliedHierarchy: LayoutHierarchySnapshot? = nil,
        selectingSources selection: Set<LayoutConductorSnapshot.Source>? = nil,
        replacingShapeGeometry replacements: [Int: [LayoutGeometry]] = [:],
        electricalContext: LayoutElectricalContext = .geometric,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> (snapshot: LayoutConductorSnapshot, probeCount: Int) {
        typealias Snapshot = LayoutConductorSnapshot
        typealias Failure = LayoutConductorCaptureError
        guard limits.maximumTechnologyRecords >= 0, limits.maximumFootprints >= 0,
              limits.maximumContactProbes >= 0, limits.decomposition.maximumInputEntries >= 0,
              limits.decomposition.maximumEdgeProbes >= 0, limits.decomposition.maximumOutputBands >= 0 else {
            throw Failure.invalidLimits
        }
        func checkCancellation() throws { if isCancelled() { throw Failure.cancelled } }
        try checkCancellation()
        var remainingRecords = limits.maximumTechnologyRecords
        for count in [tech.layers.count, tech.vias.count, tech.contacts.count, conductiveLayers.count] {
            guard count <= remainingRecords else { throw Failure.limitExceeded(.technologyRecords) }
            remainingRecords -= count
        }
        var registeredLayers: Set<LayoutLayerID> = []
        for layer in tech.layers {
            try checkCancellation()
            guard registeredLayers.insert(layer.id).inserted else { throw Failure.ambiguousLayerRole(layer.id) }
        }
        for layer in conductiveLayers {
            try checkCancellation()
            guard registeredLayers.contains(layer) else { throw Failure.unknownLayer(layer) }
        }
        var definitions: [String: LayoutViaDefinition] = [:]
        var adjacency: [LayoutLayerID: Set<LayoutLayerID>] = [:]
        var viaPairs: [LayoutLayerID: Set<LayoutLayerID>] = [:]
        var viaTopByCut: [LayoutLayerID: LayoutLayerID] = [:]
        var contactLanding: [LayoutLayerID: LayoutLayerID] = [:]
        func register(_ definition: LayoutViaDefinition) throws {
            try checkCancellation()
            guard definitions.updateValue(definition, forKey: definition.id) == nil else {
                throw Failure.duplicateTechnologyID(definition.id)
            }
            let metals: Set<LayoutLayerID> = [definition.bottomLayer, definition.topLayer]
            guard metals.count == 2, !metals.contains(definition.cutLayer) else {
                throw Failure.ambiguousLayerRole(definition.cutLayer)
            }
            if let previous = adjacency[definition.cutLayer], previous != metals || viaTopByCut[definition.cutLayer] != definition.topLayer {
                throw Failure.ambiguousLayerRole(definition.cutLayer)
            }
            adjacency[definition.cutLayer] = metals
            viaPairs[definition.cutLayer] = metals
            viaTopByCut[definition.cutLayer] = definition.topLayer
        }
        for definition in tech.vias { try register(definition) }
        for contact in tech.contacts {
            try checkCancellation()
            let definition = LayoutViaDefinition(id: contact.id, cutLayer: contact.cutLayer,
                topLayer: contact.topLayer, bottomLayer: contact.bottomLayer,
                cutSize: contact.cutSize, enclosure: contact.enclosure, cutSpacing: contact.cutSpacing)
            guard definitions.updateValue(definition, forKey: contact.id) == nil else {
                throw Failure.duplicateTechnologyID(contact.id)
            }
            let materials: Set<LayoutLayerID> = [contact.bottomLayer, contact.topLayer]
            guard materials.count == 2, !materials.contains(contact.cutLayer),
                  materials.union([contact.cutLayer]).isSubset(of: registeredLayers),
                  contactLanding[contact.cutLayer].map({ $0 == contact.topLayer }) ?? true,
                  viaPairs[contact.cutLayer].map({ $0 == materials && viaTopByCut[contact.cutLayer] == contact.topLayer }) ?? true else {
                throw Failure.ambiguousLayerRole(contact.cutLayer)
            }
            contactLanding[contact.cutLayer] = contact.topLayer
            adjacency[contact.cutLayer, default: []].formUnion(materials)
        }
        for layer in conductiveLayers where adjacency[layer] != nil { throw Failure.ambiguousLayerRole(layer) }
        let hierarchy = try suppliedHierarchy ?? captureHierarchy(document: document, cellID: cellID,
                                             limits: limits.hierarchy, isCancelled: isCancelled)
        guard replacements.keys.allSatisfy({ hierarchy.shapes.indices.contains($0) }) else {
            throw Failure.invalidComposition
        }
        let sourceNets = try Self.resolvedSourceNets(hierarchy, isCancelled: isCancelled)
        struct GeometryRecord {
            let occurrence: Int
            let source: Snapshot.Source
            let sourceID: UUID
            let layer: LayoutLayerID
            let net: Snapshot.NetReference?
        }
        var records: [GeometryRecord] = []
        var polygons: [IRBoundary] = []
        var inputEntries = 0
        let coordinateUnits = try Self.captureCoordinateUnits(hierarchy: hierarchy,
            conductiveLayers: conductiveLayers, cutLayers: Set(adjacency.keys), isCancelled: isCancelled)
        let dbu = coordinateUnits.scale.databaseUnitsPerMicrometer
        func coordinate(_ value: Double, id: UUID) throws -> Int32 {
            try Self.integerCoordinate(value, databaseUnitsPerMicrometer: dbu, sourceID: id)
        }
        func appendIntegerPolygon(_ points: [IRPoint], record: GeometryRecord) throws {
            let available = limits.decomposition.maximumInputEntries - inputEntries
            guard available > 0, points.count <= available - 1 else {
                throw Failure.decompositionFailed(.limitExceeded(.inputEntries))
            }
            inputEntries += points.count + 1
            records.append(record)
            polygons.append(IRBoundary(layer: 0, datatype: 0, points: points))
        }
        func appendGeometry(_ geometry: LayoutGeometry, record: GeometryRecord) throws {
            try checkCancellation()
            if case .path(let path) = geometry {
                try RectilinearPathFootprint.emit(path, sourceID: record.sourceID,
                    coordinate: { try coordinate($0, id: record.sourceID) }, isCancelled: isCancelled) { x, y, maxX, maxY in
                    try checkCancellation()
                    try appendIntegerPolygon([IRPoint(x: x, y: y), IRPoint(x: maxX, y: y),
                        IRPoint(x: maxX, y: maxY), IRPoint(x: x, y: maxY)], record: record)
                }
                return
            }
            if case .rect(let rect) = geometry {
                guard rect.size.width.isFinite, rect.size.height.isFinite,
                      rect.size.width > 0, rect.size.height > 0 else { throw Failure.invalidGridGeometry(record.sourceID) }
                let x = try coordinate(rect.origin.x, id: record.sourceID)
                let y = try coordinate(rect.origin.y, id: record.sourceID)
                let width = try coordinate(rect.size.width, id: record.sourceID)
                let height = try coordinate(rect.size.height, id: record.sourceID)
                let (maxX, overflowX) = x.addingReportingOverflow(width)
                let (maxY, overflowY) = y.addingReportingOverflow(height)
                guard width > 0, height > 0, !overflowX, !overflowY else { throw Failure.invalidGridGeometry(record.sourceID) }
                try appendIntegerPolygon([IRPoint(x: x, y: y), IRPoint(x: maxX, y: y),
                    IRPoint(x: maxX, y: maxY), IRPoint(x: x, y: maxY)], record: record)
                return
            }
            let count: Int
            switch geometry {
            case .rect: count = 4
            case .polygon(let polygon): count = polygon.points.count
            case .path: throw Failure.unsupportedGeometry(record.sourceID)
            }
            let available = limits.decomposition.maximumInputEntries - inputEntries
            guard available > 0, count <= available - 1 else {
                throw Failure.decompositionFailed(.limitExceeded(.inputEntries))
            }
            let points: [LayoutPoint]
            switch geometry {
            case .rect(let rect):
                guard rect.size.width.isFinite, rect.size.height.isFinite,
                      rect.size.width > 0, rect.size.height > 0 else { throw Failure.invalidGridGeometry(record.sourceID) }
                points = rect.toPolygon().points
            case .polygon(let polygon): points = polygon.points
            case .path: throw Failure.unsupportedGeometry(record.sourceID)
            }
            var integers: [IRPoint] = []
            for point in points {
                try checkCancellation()
                integers.append(IRPoint(x: try coordinate(point.x, id: record.sourceID),
                                        y: try coordinate(point.y, id: record.sourceID)))
            }
            try appendIntegerPolygon(integers, record: record)
        }
        func record(_ occurrence: Int, source: Snapshot.Source, id: UUID,
                    layer: LayoutLayerID, net: UUID?) -> GeometryRecord {
            GeometryRecord(occurrence: occurrence, source: source, sourceID: id, layer: layer,
                           net: sourceNets[source])
        }
        let sourceCells = Dictionary(uniqueKeysWithValues: document.cells.map { ($0.id, $0) })
        for (occurrenceIndex, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            for index in occurrence.shapeRange {
                if let selection, !selection.contains(.shape(index)) { continue }
                let shape = hierarchy.shapes[index]
                guard conductiveLayers.contains(shape.layer) || adjacency[shape.layer] != nil else { continue }
                if let metals = adjacency[shape.layer],
                   (!registeredLayers.contains(shape.layer) || !metals.isSubset(of: conductiveLayers)) {
                    throw Failure.ambiguousLayerRole(shape.layer)
                }
                let source = record(occurrenceIndex, source: .shape(index), id: shape.id,
                    layer: shape.layer, net: shape.netID)
                if let prepared = replacements[index] {
                    guard prepared.count <= limits.decomposition.maximumInputEntries else {
                        throw Failure.decompositionFailed(.limitExceeded(.inputEntries))
                    }
                    for geometry in prepared { try appendGeometry(geometry, record: source) }
                } else { try appendGeometry(shape.geometry, record: source) }
            }
            for index in occurrence.viaRange {
                if let selection, !selection.contains(.via(index)) { continue }
                try checkCancellation()
                let via = hierarchy.vias[index]
                guard let definition = definitions[via.viaDefinitionID] else { throw Failure.missingViaDefinition(via.viaDefinitionID) }
                let required: Set<LayoutLayerID> = [definition.cutLayer, definition.bottomLayer, definition.topLayer]
                guard required.isSubset(of: registeredLayers),
                      conductiveLayers.contains(definition.bottomLayer), conductiveLayers.contains(definition.topLayer) else {
                    throw Failure.incompleteViaTopology(viaID: via.id, definitionID: definition.id)
                }
                func emit(_ rect: LayoutRect, layer: LayoutLayerID) throws {
                    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                          rect.size.width.isFinite, rect.size.height.isFinite,
                          rect.size.width > 0, rect.size.height > 0,
                          rect.maxX.isFinite, rect.maxY.isFinite,
                          rect.maxX > rect.minX, rect.maxY > rect.minY else {
                        throw Failure.invalidGridGeometry(via.id)
                    }
                    try appendGeometry(via.geometry(forLocalRect: rect),
                        record: record(occurrenceIndex, source: .via(index), id: via.id, layer: layer, net: via.netID))
                }
                if definition.layerGeometries.isEmpty {
                    let width = definition.cutSize.width, height = definition.cutSize.height
                    guard width.isFinite, height.isFinite, width > 0, height > 0,
                          definition.enclosure.bottom.isFinite, definition.enclosure.top.isFinite,
                          definition.enclosure.bottom >= 0, definition.enclosure.top >= 0 else {
                        throw Failure.incompleteViaTopology(viaID: via.id, definitionID: definition.id)
                    }
                    let cut = LayoutRect(origin: LayoutPoint(x: -width / 2, y: -height / 2), size: definition.cutSize)
                    try emit(cut, layer: definition.cutLayer)
                    try emit(cut.expanded(by: definition.enclosure.bottom, definition.enclosure.bottom), layer: definition.bottomLayer)
                    try emit(cut.expanded(by: definition.enclosure.top, definition.enclosure.top), layer: definition.topLayer)
                } else {
                    var present: Set<LayoutLayerID> = []
                    for geometry in definition.layerGeometries {
                        try checkCancellation()
                        guard remainingRecords > 0, geometry.rects.count <= remainingRecords - 1 else {
                            throw Failure.limitExceeded(.technologyRecords)
                        }
                        remainingRecords -= geometry.rects.count + 1
                        guard required.contains(geometry.layer), !geometry.rects.isEmpty else {
                            throw Failure.incompleteViaTopology(viaID: via.id, definitionID: definition.id)
                        }
                        present.insert(geometry.layer)
                        for rect in geometry.rects { try emit(rect, layer: geometry.layer) }
                    }
                    guard present == required else { throw Failure.incompleteViaTopology(viaID: via.id, definitionID: definition.id) }
                }
            }
            for index in occurrence.pinRange {
                if let selection, !selection.contains(.pin(index)) { continue }
                let pin = hierarchy.pins[index]
                guard conductiveLayers.contains(pin.layer) else { throw Failure.unknownLayer(pin.layer) }
                let net = sourceNets[.pin(index)]
                guard let cell = sourceCells[occurrence.sourceCellID],
                      cell.pins.indices.contains(index - occurrence.pinRange.lowerBound),
                      cell.pins[index - occurrence.pinRange.lowerBound].id == pin.id else {
                    throw Failure.invalidComposition
                }
                let sourcePin = cell.pins[index - occurrence.pinRange.lowerBound]
                let points = try Self.integerPinPolygon(sourcePin, transforms: occurrence.transforms,
                    databaseUnitsPerMicrometer: dbu, isCancelled: isCancelled)
                try appendIntegerPolygon(points, record: GeometryRecord(occurrence: occurrenceIndex,
                    source: .pin(index), sourceID: pin.id, layer: pin.layer, net: net))
            }
        }
        let bands: [RectilinearBand]
        do { bands = try Region(polygons: polygons).rectilinearBands(limits: limits.decomposition, isCancelled: isCancelled) }
        catch let error as RectilinearDecompositionError { throw Failure.decompositionFailed(error) }
        var covered: Set<Int> = []
        var footprints: [Snapshot.Footprint] = []
        var pinBands = Array(repeating: [RectilinearBand](), count: hierarchy.pins.count)
        for band in bands {
            try checkCancellation()
            covered.insert(band.polygonIndex)
            let source = records[band.polygonIndex]
            if case .pin(let pin) = source.source { pinBands[pin].append(band); continue }
            guard footprints.count < limits.maximumFootprints else { throw Failure.limitExceeded(.footprints) }
            footprints.append(Snapshot.Footprint(occurrenceIndex: source.occurrence, source: source.source,
                sourceID: source.sourceID, layer: source.layer, isCut: adjacency[source.layer] != nil,
                band: band, declaredNet: source.net))
        }
        for index in records.indices where !covered.contains(index) { throw Failure.unsupportedGeometry(records[index].sourceID) }
        var probes = 0
        func chargeProbe() throws {
            try checkCancellation()
            guard probes < limits.maximumContactProbes else { throw Failure.limitExceeded(.contactProbes) }
            probes += 1
        }
        var unionFind = LayoutUnionFind(count: footprints.count)
        var contacts: [Snapshot.Contact] = []
        // ponytail: dense overlap has quadratic candidate work; the explicit probe
        // budget bounds it. Add a qualified spatial index when scale evidence requires it.
        let ordered = footprints.indices.sorted {
            footprints[$0].band.minX == footprints[$1].band.minX ? $0 < $1 : footprints[$0].band.minX < footprints[$1].band.minX
        }
        for position in ordered.indices {
            try checkCancellation()
            let firstIndex = ordered[position], first = footprints[firstIndex]
            for next in (position + 1)..<ordered.count {
                let secondIndex = ordered[next], second = footprints[secondIndex]
                if second.band.minX > first.band.maxX { break }
                try chargeProbe()
                let same = first.layer == second.layer
                let cross = first.isCut && !second.isCut && adjacency[first.layer]?.contains(second.layer) == true
                    || second.isCut && !first.isCut && adjacency[second.layer]?.contains(first.layer) == true
                guard (same || cross), try Snapshot.bandsTouch(first.band, second.band, sameLayer: same) else { continue }
                contacts.append(Snapshot.Contact(firstFootprint: min(firstIndex, secondIndex), secondFootprint: max(firstIndex, secondIndex)))
                unionFind.union(firstIndex, secondIndex)
            }
        }
        contacts.sort { ($0.firstFootprint, $0.secondFootprint) < ($1.firstFootprint, $1.secondFootprint) }
        var groups: [[Int]] = []
        var componentByRoot: [Int: Int] = [:]
        var componentByFootprint: [Int] = []
        for index in footprints.indices {
            try checkCancellation()
            let root = unionFind.find(index)
            let component: Int
            if let existing = componentByRoot[root] { component = existing }
            else { component = groups.count; componentByRoot[root] = component; groups.append([]) }
            groups[component].append(index)
            componentByFootprint.append(component)
        }
        var pins: [Snapshot.Pin] = []
        for source in records {
            guard case .pin(let pinIndex) = source.source else { continue }
            try checkCancellation()
            var componentSet: Set<Int> = []
            var footprintSet: Set<Int> = []
            for band in pinBands[pinIndex] {
                for index in ordered {
                    let footprint = footprints[index]
                    if footprint.band.minX > band.maxX { break }
                    try chargeProbe()
                    guard !footprint.isCut, footprint.layer == source.layer,
                          try Snapshot.bandsTouch(band, footprint.band, sameLayer: false) else { continue }
                    componentSet.insert(componentByFootprint[index])
                    footprintSet.insert(index)
                }
            }
            let components = componentSet.sorted()
            pins.append(Snapshot.Pin(occurrenceIndex: source.occurrence, sourcePinIndex: pinIndex,
                declaredNet: source.net, bands: pinBands[pinIndex], footprintIndices: footprintSet.sorted(), componentIndices: components))
        }
        try checkCancellation()
        let snapshot = try Self.finishCapturedSnapshot(hierarchy: hierarchy, coordinateUnits: coordinateUnits,
            conductiveLayers: conductiveLayers, adjacency: adjacency, tech: tech, footprints: footprints,
            polygonSources: records.map(\.source), contacts: contacts, groups: groups, pins: pins, sourceNets: sourceNets, electricalContext: electricalContext, preparedShapeGeometry: replacements,
            isCancelled: isCancelled)
        return (snapshot, probes)
    }

    static func integerCoordinate(_ value: Double, databaseUnitsPerMicrometer dbu: Double,
        sourceID: UUID) throws -> Int32 {
        let scaled = value * dbu, rounded = scaled.rounded()
        guard value.isFinite, scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
              let integer = Int32(exactly: rounded) else { throw LayoutConductorCaptureError.invalidGridGeometry(sourceID) }
        return integer
    }

    static func captureCoordinateUnits(
        hierarchy: LayoutHierarchySnapshot, conductiveLayers: Set<LayoutLayerID>, cutLayers: Set<LayoutLayerID>,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> LayoutUnits {
        func refined() throws -> LayoutUnits {
            do { return LayoutUnits(scale: try .init(
                databaseUnitsPerMicrometer: hierarchy.units.scale.databaseUnitsPerMicrometer * 2)) }
            catch { throw LayoutConductorCaptureError.invalidCoordinateUnits }
        }
        for pin in hierarchy.pins {
            if isCancelled() { throw LayoutConductorCaptureError.cancelled }
            if conductiveLayers.contains(pin.layer) { return try refined() }
        }
        for shape in hierarchy.shapes {
            if isCancelled() { throw LayoutConductorCaptureError.cancelled }
            guard conductiveLayers.contains(shape.layer) || cutLayers.contains(shape.layer) else { continue }
            if case .path = shape.geometry {
                return try refined()
            }
        }
        return hierarchy.units
    }

    /// Shared reduction of native full capture and a verified live partition.
    static func finishCapturedSnapshot(
        hierarchy: LayoutHierarchySnapshot, coordinateUnits: LayoutUnits, conductiveLayers: Set<LayoutLayerID>,
        adjacency: [LayoutLayerID: Set<LayoutLayerID>], tech: LayoutTechDatabase,
        footprints: [LayoutConductorSnapshot.Footprint], polygonSources: [LayoutConductorSnapshot.Source],
        contacts: [LayoutConductorSnapshot.Contact], groups: [[Int]], pins: [LayoutConductorSnapshot.Pin],
        sourceNets: [LayoutConductorSnapshot.Source: LayoutConductorSnapshot.NetReference],
        electricalContext: LayoutElectricalContext = .geometric, preparedShapeGeometry: [Int: [LayoutGeometry]] = [:],
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> LayoutConductorSnapshot {
        typealias Snapshot = LayoutConductorSnapshot
        func checkCancellation() throws { if isCancelled() { throw LayoutConductorCaptureError.cancelled } }
        var nets = try groups.map { indices in
            try checkCancellation()
            return Set(indices.compactMap { footprints[$0].declaredNet })
        }
        var componentPins = Array(repeating: [Int](), count: groups.count)
        for (pinIndex, pin) in pins.enumerated() {
            try checkCancellation()
            for component in pin.componentIndices {
                componentPins[component].append(pinIndex)
                if let net = pin.declaredNet { nets[component].insert(net) }
            }
        }
        func netOrder(_ first: Snapshot.NetReference, _ second: Snapshot.NetReference) -> Bool {
            first.occurrenceIndex == second.occurrenceIndex ? first.netID.isCanonicallyOrderedBefore(second.netID) : first.occurrenceIndex < second.occurrenceIndex
        }
        let components = try groups.indices.map { index in
            try checkCancellation()
            return Snapshot.Component(footprintIndices: groups[index], declaredNets: nets[index].sorted(by: netOrder), pinIndices: componentPins[index])
        }
        var netComponents: [Snapshot.NetReference: [Int]] = [:]
        var unconnectedPins: [Snapshot.NetReference: [Int]] = [:]
        for index in components.indices {
            try checkCancellation()
            for net in components[index].declaredNets { netComponents[net, default: []].append(index) }
        }
        for index in pins.indices where pins[index].componentIndices.isEmpty {
            try checkCancellation()
            if let net = pins[index].declaredNet { unconnectedPins[net, default: []].append(index) }
        }
        let declared = Set(netComponents.keys).union(unconnectedPins.keys).sorted(by: netOrder)
        let opens = try declared.compactMap { net -> Snapshot.Open? in
            try checkCancellation()
            let components = netComponents[net, default: []], unconnected = unconnectedPins[net, default: []]
            return components.count > 1 || !unconnected.isEmpty ? Snapshot.Open(net: net, componentIndices: components, unconnectedPinIndices: unconnected) : nil
        }
        return Snapshot(electricalContext: electricalContext, preparedShapeGeometry: preparedShapeGeometry, hierarchy: hierarchy, coordinateUnits: coordinateUnits, conductiveLayers: conductiveLayers,
            adjacentConductorLayersByCut: adjacency, contactTechnology: tech, declaredNetBySource: sourceNets, footprints: footprints,
            polygonSources: polygonSources, contacts: contacts, components: components, pins: pins, opens: opens,
            shortComponentIndices: components.indices.filter { components[$0].declaredNets.count > 1 })
    }
}
