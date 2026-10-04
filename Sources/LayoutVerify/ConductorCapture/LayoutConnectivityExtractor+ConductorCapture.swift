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
        func register(_ definition: LayoutViaDefinition) throws {
            try checkCancellation()
            guard definitions.updateValue(definition, forKey: definition.id) == nil else {
                throw Failure.duplicateTechnologyID(definition.id)
            }
            let metals: Set<LayoutLayerID> = [definition.bottomLayer, definition.topLayer]
            guard metals.count == 2, !metals.contains(definition.cutLayer) else {
                throw Failure.ambiguousLayerRole(definition.cutLayer)
            }
            if let previous = adjacency[definition.cutLayer], previous != metals {
                throw Failure.ambiguousLayerRole(definition.cutLayer)
            }
            adjacency[definition.cutLayer] = metals
        }
        for definition in tech.vias { try register(definition) }
        for contact in tech.contacts {
            try register(LayoutViaDefinition(id: contact.id, cutLayer: contact.cutLayer,
                topLayer: contact.topLayer, bottomLayer: contact.bottomLayer,
                cutSize: contact.cutSize, enclosure: contact.enclosure, cutSpacing: contact.cutSpacing))
        }
        for layer in conductiveLayers where adjacency[layer] != nil { throw Failure.ambiguousLayerRole(layer) }
        let hierarchy = try captureHierarchy(document: document, cellID: cellID,
                                             limits: limits.hierarchy, isCancelled: isCancelled)
        var aliases: [[UUID: Snapshot.NetReference]] = []
        func resolved(_ net: UUID, occurrence: Int) -> Snapshot.NetReference {
            aliases[occurrence][net] ?? Snapshot.NetReference(occurrenceIndex: occurrence, netID: net)
        }
        for (index, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            var local: [UUID: Snapshot.NetReference] = [:]
            if let parent = occurrence.parentIndex {
                let names = Set(occurrence.pinRange.map { hierarchy.pins[$0].name })
                for name in occurrence.terminalNetIDs.keys {
                    try checkCancellation()
                    guard names.contains(name) else { throw Failure.unknownTerminal(occurrenceIndex: index, name: name) }
                }
                for pinIndex in occurrence.pinRange {
                    let pin = hierarchy.pins[pinIndex]
                    guard let localNet = pin.netID, let parentNet = occurrence.terminalNetIDs[pin.name] else { continue }
                    let reference = resolved(parentNet, occurrence: parent)
                    if let previous = local[localNet], previous != reference {
                        throw Failure.conflictingTerminalBinding(occurrenceIndex: index, netID: localNet)
                    }
                    local[localNet] = reference
                }
            }
            aliases.append(local)
        }
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
        let dbu = document.units.scale.databaseUnitsPerMicrometer
        func coordinate(_ value: Double, id: UUID) throws -> Int32 {
            let scaled = value * dbu
            let rounded = scaled.rounded()
            guard value.isFinite, scaled.isFinite, abs(scaled - rounded) <= scaled.ulp * 4,
                  let integer = Int32(exactly: rounded) else { throw Failure.invalidGridGeometry(id) }
            return integer
        }
        func appendGeometry(_ geometry: LayoutGeometry, record: GeometryRecord) throws {
            try checkCancellation()
            let count: Int
            switch geometry {
            case .rect: count = 4
            case .polygon(let polygon): count = polygon.points.count
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native contact capture cannot yet
            // represent path caps/joins exactly. Direct captureConductors callers
            // receive typed failure; admit paths only after exact decomposition
            // and success/failure contact tests establish their footprint.
            case .path: throw Failure.unsupportedGeometry(record.sourceID)
            }
            let available = limits.decomposition.maximumInputEntries - inputEntries
            guard available > 0, count <= available - 1 else {
                throw Failure.decompositionFailed(.limitExceeded(.inputEntries))
            }
            inputEntries += count + 1
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
            records.append(record)
            polygons.append(IRBoundary(layer: 0, datatype: 0, points: integers))
        }
        func record(_ occurrence: Int, source: Snapshot.Source, id: UUID,
                    layer: LayoutLayerID, net: UUID?) -> GeometryRecord {
            GeometryRecord(occurrence: occurrence, source: source, sourceID: id, layer: layer,
                           net: net.map { resolved($0, occurrence: occurrence) })
        }
        for (occurrenceIndex, occurrence) in hierarchy.occurrences.enumerated() {
            try checkCancellation()
            for index in occurrence.shapeRange {
                let shape = hierarchy.shapes[index]
                guard conductiveLayers.contains(shape.layer) || adjacency[shape.layer] != nil else { continue }
                if let metals = adjacency[shape.layer],
                   (!registeredLayers.contains(shape.layer) || !metals.isSubset(of: conductiveLayers)) {
                    throw Failure.ambiguousLayerRole(shape.layer)
                }
                try appendGeometry(shape.geometry, record: record(occurrenceIndex, source: .shape(index),
                    id: shape.id, layer: shape.layer, net: shape.netID))
            }
            for index in occurrence.viaRange {
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
                let pin = hierarchy.pins[index]
                guard conductiveLayers.contains(pin.layer) else { throw Failure.unknownLayer(pin.layer) }
                let net: Snapshot.NetReference?
                if let sourceNet = pin.netID { net = resolved(sourceNet, occurrence: occurrenceIndex) }
                else if let parent = occurrence.parentIndex, let bound = occurrence.terminalNetIDs[pin.name] {
                    net = resolved(bound, occurrence: parent)
                } else { net = nil }
                try appendGeometry(hierarchy.pinGeometries[index], record: GeometryRecord(occurrence: occurrenceIndex,
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
        func overlaps(_ first: RectilinearBand, _ second: RectilinearBand, sameLayer: Bool) -> Bool {
            let x = Int64(min(first.maxX, second.maxX)) - Int64(max(first.minX, second.minX))
            let y = Int64(min(first.maxY, second.maxY)) - Int64(max(first.minY, second.minY))
            return sameLayer ? (x > 0 && y >= 0 || x >= 0 && y > 0) : (x > 0 && y > 0)
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
                guard (same || cross), overlaps(first.band, second.band, sameLayer: same) else { continue }
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
        var nets = groups.map { Set($0.compactMap { footprints[$0].declaredNet }) }
        var componentPins = Array(repeating: [Int](), count: groups.count)
        var pins: [Snapshot.Pin] = []
        for source in records {
            guard case .pin(let pinIndex) = source.source else { continue }
            try checkCancellation()
            var componentSet: Set<Int> = []
            for band in pinBands[pinIndex] {
                for index in ordered {
                    let footprint = footprints[index]
                    if footprint.band.minX > band.maxX { break }
                    try chargeProbe()
                    guard !footprint.isCut, footprint.layer == source.layer,
                          overlaps(band, footprint.band, sameLayer: false) else { continue }
                    componentSet.insert(componentByFootprint[index])
                }
            }
            let components = componentSet.sorted()
            let outputPin = pins.count
            for component in components {
                componentPins[component].append(outputPin)
                if let net = source.net { nets[component].insert(net) }
            }
            pins.append(Snapshot.Pin(occurrenceIndex: source.occurrence, sourcePinIndex: pinIndex,
                declaredNet: source.net, bands: pinBands[pinIndex], componentIndices: components))
        }
        func netOrder(_ first: Snapshot.NetReference, _ second: Snapshot.NetReference) -> Bool {
            first.occurrenceIndex == second.occurrenceIndex ? first.netID.isCanonicallyOrderedBefore(second.netID) : first.occurrenceIndex < second.occurrenceIndex
        }
        let components = groups.indices.map { Snapshot.Component(footprintIndices: groups[$0], declaredNets: nets[$0].sorted(by: netOrder), pinIndices: componentPins[$0]) }
        var netComponents: [Snapshot.NetReference: [Int]] = [:]
        var unconnectedPins: [Snapshot.NetReference: [Int]] = [:]
        for index in components.indices {
            try checkCancellation()
            for net in components[index].declaredNets { netComponents[net, default: []].append(index) }
        }
        for index in pins.indices where pins[index].componentIndices.isEmpty {
            if let net = pins[index].declaredNet { unconnectedPins[net, default: []].append(index) }
        }
        let declared = Set(netComponents.keys).union(unconnectedPins.keys).sorted(by: netOrder)
        let opens = declared.compactMap { net -> Snapshot.Open? in
            let components = netComponents[net, default: []], unconnected = unconnectedPins[net, default: []]
            return components.count > 1 || !unconnected.isEmpty ? Snapshot.Open(net: net, componentIndices: components, unconnectedPinIndices: unconnected) : nil
        }
        try checkCancellation()
        return Snapshot(hierarchy: hierarchy, conductiveLayers: conductiveLayers, footprints: footprints,
            contacts: contacts, components: components, pins: pins, opens: opens,
            shortComponentIndices: components.indices.filter { components[$0].declaredNets.count > 1 })
    }
}
