import Foundation
import LayoutCore
import LayoutTech

public enum DeviceExtractionError: Error, Equatable, Sendable {
    case targetCellNotFound
}

/// Extracts MOSFET-level comparison netlists from layout geometry.
///
/// Recognition is intentionally narrow and explicit: a MOSFET channel is a
/// positive-area intersection of a rectangular `POLY` and a rectangular
/// `ACTIVE` where the poly fully crosses the active along one axis (either
/// orientation). `NIMP` / `PIMP` coverage of the channel decides NMOS or
/// PMOS. Anything outside that shape class is reported as an issue, never
/// silently guessed.
///
/// Terminal nets are resolved by geometric connectivity, not by declared
/// intent: each active is split into source/drain slabs on either side of
/// its channels, contact-cut shapes bridge layers exactly like vias, and a
/// terminal's net is the connected island its conductor belongs to.
/// Disconnecting a gate or source therefore changes the extracted netlist.
/// Declared net IDs and pins only provide the island NAMES used to match
/// the reference; islands without either get a deterministic anonymous
/// name that can never match a named reference net.
///
/// The bulk terminal is the exception: substrate/well connectivity is not
/// part of the drawn conductor stack, so bulk still resolves to the
/// nearest bulk-role pin (with an explicit issue when none exists).
public struct DeviceExtractor: Sendable {
    private let activeLayer = LayoutLayerID(name: "ACTIVE", purpose: "drawing")
    private let polyLayer = LayoutLayerID(name: "POLY", purpose: "drawing")
    private let nimpLayer = LayoutLayerID(name: "NIMP", purpose: "drawing")
    private let pimpLayer = LayoutLayerID(name: "PIMP", purpose: "drawing")

    /// Coordinate slack for "fully crosses" and slab-boundary tests.
    /// Flattened coordinates are normalized by the transform pipeline, so
    /// sub-nanometre slack is enough without masking real gaps.
    private let eps = 1e-6

    public init() {}

    public func extract(
        document: LayoutDocument,
        tech: LayoutTechDatabase,
        cellID: UUID? = nil
    ) throws -> DeviceExtractionResult {
        let service = LayoutDRCService()
        guard let targetCell = service.resolveCell(document: document, cellID: cellID) else {
            throw DeviceExtractionError.targetCellNotFound
        }
        let hierarchy = try LayoutConnectivityExtractor().captureHierarchy(document: document, cellID: targetCell.id)
        guard let root = hierarchy.occurrences.firstIndex(where: {
            $0.parentIndex == nil && $0.sourceCellID == hierarchy.rootCellID
        }) else { throw DeviceExtractionError.targetCellNotFound }
        let shapes = hierarchy.shapes, vias = hierarchy.vias
        var pins = hierarchy.pins
        for (occurrenceIndex, occurrence) in hierarchy.occurrences.enumerated() where occurrenceIndex != root {
            let prefix = occurrencePrefix(occurrence)
            for pinIndex in occurrence.pinRange { pins[pinIndex].name = prefix + pins[pinIndex].name }
        }
        var issues: [DeviceExtractionIssue] = []

        let actives = recognizeActives(shapes: shapes, issues: &issues)
        let channelsByActive = try discoverChannels(
            shapes: shapes,
            actives: actives,
            issues: &issues
        )
        let connectivity = try buildConnectivity(
            document: document, hierarchy: hierarchy,
            shapes: shapes,
            vias: vias,
            actives: actives,
            channelsByActive: channelsByActive,
            tech: tech,
            service: service
        )
        let pinIslandByIndex = mapPinsToIslands(pins: pins, connectivity: connectivity)
        for pin in connectivity.snapshot.pins where pin.componentIndices.count != 1 && pins[pin.sourcePinIndex].role != .bulk {
            issues.append(DeviceExtractionIssue(kind: .openNet,
                message: "Pin '\(pins[pin.sourcePinIndex].name)' contacts \(pin.componentIndices.count) conductor islands.",
                region: pinRect(pins[pin.sourcePinIndex]), policyApplicability: .layoutRepairRequired,
                suggestedActions: ["connect-pin-to-one-island"]))
        }
        // Declared nets that carry a NAME speak the same currency as
        // `.subckt` references ("pin:<name>"); anonymous net IDs keep the
        // uuid form. Names come from the target cell's net table — the
        // label→net annotation pass writes exactly there.
        var netNameByID: [LayoutConductorSnapshot.NetReference: String] = [:]
        for (occurrenceIndex, occurrence) in hierarchy.occurrences.enumerated() {
            guard let source = document.cell(withID: occurrence.sourceCellID) else { throw DeviceExtractionError.targetCellNotFound }
            let prefix = occurrenceIndex == root ? "" : occurrencePrefix(occurrence)
            for net in source.nets {
                netNameByID[.init(occurrenceIndex: occurrenceIndex, netID: net.id)] = prefix + net.name
            }
        }
        let labels = try flattenedLabels(hierarchy: hierarchy, document: document, root: root)
        let labelsByIsland = mapLabelsToIslands(labels: labels, connectivity: connectivity)
        let rootLabels = targetCell.labels
        let rootLabelsByIsland = mapLabelsToIslands(labels: rootLabels, connectivity: connectivity)
        let islandNames = nameIslands(
            connectivity: connectivity,
            pins: pins,
            pinIslandByIndex: pinIslandByIndex,
            labelsByIsland: labelsByIsland,
            netNameByID: netNameByID,
            issues: &issues
        )

        var devices = recognizeDevices(
            shapes: shapes,
            actives: actives,
            channelsByActive: channelsByActive,
            connectivity: connectivity,
            islandNames: islandNames,
            pins: pins,
            pinIslandByIndex: pinIslandByIndex,
            fallbackPinNames: Dictionary(uniqueKeysWithValues: pins.indices.map { index in
                (index, comparisonName(for: connectivity.snapshot.declaredNetBySource[.pin(index)], fallback: pins[index].name, names: netNameByID, hierarchy: hierarchy, root: root))
            }),
            issues: &issues
        )
        devices = groupedDevices(devices)
        devices.sort {
            if $0.region.minX != $1.region.minX { return $0.region.minX < $1.region.minX }
            if $0.region.minY != $1.region.minY { return $0.region.minY < $1.region.minY }
            return $0.id < $1.id
        }

        // Only the target cell's OWN pins define its subckt interface.
        // Flattened child pins are device terminal markers: two instances
        // of one device cell both expose "gate", legitimately on
        // different nets — an interface built from them would conflict.
        let ports = ports(
            from: pins, rootPinRange: hierarchy.occurrences[root].pinRange,
            pinIslandByIndex: pinIslandByIndex,
            labelsByIsland: rootLabelsByIsland,
            declaredNetsByIsland: connectivity.declaredNetsByIsland,
            netNameByID: netNameByID,
            islandNames: islandNames,
            connectivity: connectivity,
            root: root,
            issues: &issues
        )
        return DeviceExtractionResult(
            netlist: ComparisonNetlist(devices: devices, ports: ports),
            issues: issues
        )
    }

    // MARK: - Geometry recognition

    private struct Active {
        var flatIndex: Int
        var rect: LayoutRect
        var netID: UUID?
    }

    private struct Channel {
        var polyFlatIndex: Int
        var rect: LayoutRect
        /// Poly crosses the full active height, so current flows along x.
        var horizontalCurrent: Bool
    }

    /// Axis-aligned rectangle behind a geometry, if it has one. Flattening
    /// canonicalizes instanced rects into 4-point polygons, so both forms
    /// are accepted.
    private func rectLike(_ geometry: LayoutGeometry) -> LayoutRect? {
        switch geometry {
        case .rect(let rect):
            guard rect.size.width > 0, rect.size.height > 0 else { return nil }
            return rect
        case .polygon(let polygon):
            var points = polygon.points
            if points.count >= 2, points.first == points.last {
                points.removeLast()
            }
            guard points.count == 4 else { return nil }
            // Rotation transforms leave sin/cos noise (~1e-16) on the
            // coordinates, so axis-alignment is judged by eps clustering,
            // not exact equality.
            guard let xs = twoClusters(points.map(\.x)),
                  let ys = twoClusters(points.map(\.y)) else {
                return nil
            }
            var cornersSeen = Set<Int>()
            for point in points {
                let xIndex = abs(point.x - xs.low) <= eps ? 0 : 1
                let yIndex = abs(point.y - ys.low) <= eps ? 0 : 1
                cornersSeen.insert(xIndex * 2 + yIndex)
            }
            guard cornersSeen.count == 4 else { return nil }
            return LayoutRect(
                origin: LayoutPoint(x: xs.low, y: ys.low),
                size: LayoutSize(width: xs.high - xs.low, height: ys.high - ys.low)
            )
        case .path:
            return nil
        }
    }

    /// Splits four coordinates into exactly two eps-tight clusters with a
    /// positive gap between them; nil when the values do not form two
    /// distinct axis levels.
    private func twoClusters(_ values: [Double]) -> (low: Double, high: Double)? {
        let sorted = values.sorted()
        guard sorted.count == 4 else { return nil }
        guard sorted[1] - sorted[0] <= eps,
              sorted[3] - sorted[2] <= eps,
              sorted[2] - sorted[1] > eps else {
            return nil
        }
        return (low: sorted[0], high: sorted[3])
    }

    private func recognizeActives(
        shapes: [LayoutShape],
        issues: inout [DeviceExtractionIssue]
    ) -> [Active] {
        var actives: [Active] = []
        for (index, shape) in shapes.enumerated() where shape.layer == activeLayer {
            guard let rect = rectLike(shape.geometry) else {
                issues.append(DeviceExtractionIssue(
                    kind: .unrecognizedChannel,
                    message: "ACTIVE geometry is not an axis-aligned rectangle.",
                    region: LayoutGeometryAnalysis.boundingBox(for: shape.geometry),
                    shapeIDs: [shape.id],
                    affectedLayers: [activeLayer],
                    policyApplicability: .layoutRepairRequired,
                    suggestedActions: ["replace-active-with-rectangular-geometry", "inspect-layer-mapping"]
                ))
                continue
            }
            actives.append(Active(flatIndex: index, rect: rect, netID: shape.netID))
        }
        return actives
    }

    /// Channels per active ordinal. An active whose channels cannot be
    /// laid out as parallel full crossings maps to `nil` (issue emitted)
    /// and contributes no devices; its geometry stays whole in the
    /// connectivity stage so wiring through it is still honest.
    private func discoverChannels(
        shapes: [LayoutShape],
        actives: [Active],
        issues: inout [DeviceExtractionIssue],
        limits: LayoutConductorCaptureLimits = .default
    ) throws -> [Int: [Channel]?] {
        var probes = 0
        var polys: [(index: Int, shape: LayoutShape, rect: LayoutRect)] = []
        for (index, shape) in shapes.enumerated() {
            if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
            if shape.layer == polyLayer, let rect = rectLike(shape.geometry) { polys.append((index, shape, rect)) }
        }
        var result: [Int: [Channel]?] = [:]
        for (activeOrdinal, active) in actives.enumerated() {
            var channels: [Channel] = []
            var invalid = false
            for (index, shape, polyRect) in polys {
                if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
                guard probes < limits.maximumContactProbes else { throw LayoutConductorCaptureError.limitExceeded(.contactProbes) }
                probes += 1
                guard let channel = positiveIntersection(active.rect, polyRect) else { continue }
                let fullHeight = channel.minY <= active.rect.minY + eps
                    && channel.maxY >= active.rect.maxY - eps
                let fullWidth = channel.minX <= active.rect.minX + eps
                    && channel.maxX >= active.rect.maxX - eps
                switch (fullHeight, fullWidth) {
                case (true, true):
                    issues.append(DeviceExtractionIssue(
                        kind: .unrecognizedChannel,
                        message: "POLY covers the whole ACTIVE; no source/drain regions remain.",
                        region: channel,
                        shapeIDs: [shapes[active.flatIndex].id, shape.id],
                        affectedLayers: [activeLayer, polyLayer],
                        policyApplicability: .layoutRepairRequired,
                        suggestedActions: ["repair-channel-geometry", "inspect-active-poly-crossing"]
                    ))
                    invalid = true
                case (false, false):
                    issues.append(DeviceExtractionIssue(
                        kind: .unrecognizedChannel,
                        message: "POLY only partially crosses ACTIVE; the channel is not a full crossing.",
                        region: channel,
                        shapeIDs: [shapes[active.flatIndex].id, shape.id],
                        affectedLayers: [activeLayer, polyLayer],
                        policyApplicability: .layoutRepairRequired,
                        suggestedActions: ["repair-channel-geometry", "inspect-active-poly-crossing"]
                    ))
                    invalid = true
                case (true, false):
                    channels.append(Channel(
                        polyFlatIndex: index,
                        rect: channel,
                        horizontalCurrent: true
                    ))
                case (false, true):
                    channels.append(Channel(
                        polyFlatIndex: index,
                        rect: channel,
                        horizontalCurrent: false
                    ))
                }
            }
            guard !invalid else {
                result[activeOrdinal] = Optional<[Channel]>.none
                continue
            }
            guard !channels.isEmpty else {
                result[activeOrdinal] = [Channel]()
                continue
            }
            let horizontal = channels[0].horizontalCurrent
            guard channels.allSatisfy({ $0.horizontalCurrent == horizontal }) else {
                issues.append(DeviceExtractionIssue(
                    kind: .unrecognizedChannel,
                    message: "ACTIVE carries channels of mixed orientation.",
                    region: actives[activeOrdinal].rect,
                    shapeIDs: [shapes[active.flatIndex].id] + channels.map { shapes[$0.polyFlatIndex].id },
                    affectedLayers: [activeLayer, polyLayer],
                    policyApplicability: .layoutRepairRequired,
                    suggestedActions: ["repair-channel-geometry", "inspect-active-poly-crossing"]
                ))
                result[activeOrdinal] = Optional<[Channel]>.none
                continue
            }
            channels.sort {
                horizontal ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
            }
            var overlapping = false
            for index in 1..<channels.count {
                let previous = channels[index - 1].rect
                let current = channels[index].rect
                let gap = horizontal
                    ? current.minX - previous.maxX
                    : current.minY - previous.maxY
                if gap < -eps { overlapping = true }
            }
            if overlapping {
                issues.append(DeviceExtractionIssue(
                    kind: .unrecognizedChannel,
                    message: "Channels overlap on one ACTIVE.",
                    region: actives[activeOrdinal].rect,
                    shapeIDs: [shapes[active.flatIndex].id] + channels.map { shapes[$0.polyFlatIndex].id },
                    affectedLayers: [activeLayer, polyLayer],
                    policyApplicability: .layoutRepairRequired,
                    suggestedActions: ["repair-channel-geometry", "inspect-active-poly-crossing"]
                ))
                result[activeOrdinal] = Optional<[Channel]>.none
                continue
            }
            result[activeOrdinal] = channels
        }
        return result
    }

    // MARK: - Connectivity stage

    private struct Connectivity {
        var islandIndexByKey: [ConnectivityElementKey: Int]
        var elements: [ConnectivityElementKey: ConnectivityElement]
        /// Declared nets per island, unique and sorted by uuidString.
        var declaredNetsByIsland: [Int: [LayoutConductorSnapshot.NetReference]]
        var islandCount: Int
        var snapshot: LayoutConductorSnapshot
        var root: Int
        /// Element key of each poly shape, by flatten index.
        var polyKeyByFlatIndex: [Int: ConnectivityElementKey]
        /// Slab element keys per active ordinal, in channel order:
        /// slab k sits before channel k, slab k+1 after it. `nil` entries
        /// are zero-width gaps (channel at the active edge).
        var slabKeysByActiveOrdinal: [Int: [ConnectivityElementKey?]]
        var slabRectsByActiveOrdinal: [Int: [LayoutRect?]]
        /// Element key of every shape that conducts as-is (metal, tap
        /// actives — not poly, cuts, or channel-split actives), by
        /// flatten index.
        var plainShapeKeyByFlatIndex: [Int: ConnectivityElementKey]
    }

    /// Builds the conductor element table the way the device sees it:
    /// channel-bearing actives are replaced by their source/drain slabs,
    /// contact-cut shapes become layer bridges like vias, everything else
    /// conducts within its own layer. Keys are deterministic flatten-order
    /// ordinals, so two extractions of the same document agree exactly.
    private func buildConnectivity(
        document: LayoutDocument, hierarchy: LayoutHierarchySnapshot,
        shapes: [LayoutShape], vias: [LayoutVia], actives: [Active],
        channelsByActive: [Int: [Channel]?], tech: LayoutTechDatabase, service: LayoutDRCService
    ) throws -> Connectivity {
        let preparation = try prepareConductors(shapes: shapes, actives: actives,
            channelsByActive: channelsByActive, tech: tech, limits: .default)
        let slabRectsByActiveOrdinal = preparation.slabs
        let snapshot = try capturePrepared(document: document, tech: tech, hierarchy: hierarchy,
            preparation: preparation, limits: .default)
        guard let root = hierarchy.occurrences.firstIndex(where: { $0.parentIndex == nil && $0.sourceCellID == hierarchy.rootCellID }) else {
            throw DeviceExtractionError.targetCellNotFound
        }
        let captured = try LayoutConnectivityExtractor.capturedElements(snapshot)
        var keysBySource: [Int: [ConnectivityElementKey]] = [:]
        for (index, footprint) in snapshot.footprints.enumerated() {
            if case .shape(let source) = footprint.source { keysBySource[source, default: []].append(captured.keys[index]) }
        }
        var islandIndexByKey: [ConnectivityElementKey: Int] = [:]
        var declared: [Int: [LayoutConductorSnapshot.NetReference]] = [:]
        for (index, component) in snapshot.components.enumerated() {
            declared[index] = component.declaredNets
            for footprint in component.footprintIndices { islandIndexByKey[captured.keys[footprint]] = index }
        }
        var polyKeys: [Int: ConnectivityElementKey] = [:], plainKeys: [Int: ConnectivityElementKey] = [:]
        for source in shapes.indices {
            if shapes[source].layer == polyLayer { polyKeys[source] = keysBySource[source]?.first }
            else { plainKeys[source] = keysBySource[source]?.first }
        }
        var slabKeys: [Int: [ConnectivityElementKey?]] = [:]
        for (ordinal, slabs) in slabRectsByActiveOrdinal {
            let keys = keysBySource[actives[ordinal].flatIndex, default: []]
            guard keys.count == slabs.compactMap({ $0 }).count else { throw LayoutConductorCaptureError.invalidComposition }
            var cursor = 0
            slabKeys[ordinal] = slabs.map { slab in
                guard slab != nil else { return nil }
                defer { cursor += 1 }
                return keys[cursor]
            }
        }
        return Connectivity(islandIndexByKey: islandIndexByKey, elements: captured.elements,
            declaredNetsByIsland: declared, islandCount: snapshot.components.count, snapshot: snapshot, root: root,
            polyKeyByFlatIndex: polyKeys, slabKeysByActiveOrdinal: slabKeys,
            slabRectsByActiveOrdinal: slabRectsByActiveOrdinal, plainShapeKeyByFlatIndex: plainKeys)
    }

    struct ConductorPreparation {
        let layers: Set<LayoutLayerID>
        let replacements: [Int: [LayoutGeometry]]
        let slabs: [Int: [LayoutRect?]]
    }

    /// Bounded immutable electrical facts with Device-owned channel separation.
    /// The hierarchy remains the original source generation, not slab geometry.
    public func captureConductors(document: LayoutDocument, tech: LayoutTechDatabase, cellID: UUID? = nil,
        limits: LayoutConductorCaptureLimits = .default, electricalContext: LayoutElectricalContext = .deviceAwareMOS
    ) throws -> LayoutConductorSnapshot {
        let hierarchy = try LayoutConnectivityExtractor().captureHierarchy(document: document, cellID: cellID, limits: limits.hierarchy)
        let preparation = try prepareConductors(hierarchy: hierarchy, tech: tech, limits: limits, electricalContext: electricalContext)
        return try capturePrepared(document: document, tech: tech, hierarchy: hierarchy, preparation: preparation,
            limits: limits, electricalContext: electricalContext)
    }

    func prepareConductors(hierarchy: LayoutHierarchySnapshot, tech: LayoutTechDatabase,
        limits: LayoutConductorCaptureLimits, electricalContext: LayoutElectricalContext = .deviceAwareMOS
    ) throws -> ConductorPreparation {
        guard limits.maximumContactProbes >= 0 else { throw LayoutConductorCaptureError.invalidLimits }
        var issues: [DeviceExtractionIssue] = []
        let actives = recognizeActives(shapes: hierarchy.shapes, issues: &issues)
        let channels = try discoverChannels(shapes: hierarchy.shapes, actives: actives, issues: &issues, limits: limits)
        guard issues.isEmpty else { throw LayoutConductorCaptureError.unsupportedDevicePreparation }
        let preparation = try prepareConductors(shapes: hierarchy.shapes, actives: actives, channelsByActive: channels,
            tech: tech, limits: limits)
        switch electricalContext {
        case .geometric: throw LayoutConductorCaptureError.unsupportedDevicePreparation
        case .deviceAwareMOS: return preparation
        case .deviceAwareMOSAndPolyResistors(let poly, let marker):
            let polyCount = hierarchy.shapes.reduce(0) { $0 + ($1.layer == polyLayer && rectLike($1.geometry) != nil ? 1 : 0) }
            let (mosProbes, overflow) = actives.count.multipliedReportingOverflow(by: polyCount)
            guard !overflow, mosProbes <= limits.maximumContactProbes else { throw LayoutConductorCaptureError.limitExceeded(.contactProbes) }
            return try PolyResistorConductorPreparation.apply(hierarchy: hierarchy, tech: tech,
                polyLayer: poly, bodyMarkerLayer: marker, preparation: preparation, limits: limits,
                remainingProbes: limits.maximumContactProbes - mosProbes)
        }
    }

    private func prepareConductors(shapes: [LayoutShape], actives: [Active], channelsByActive: [Int: [Channel]?],
        tech: LayoutTechDatabase, limits: LayoutConductorCaptureLimits
    ) throws -> ConductorPreparation {
        _ = try LayoutConnectivityExtractor.productionConductiveLayers(tech, limits: limits)
        var selectedLayers: Set<LayoutLayerID> = []
        for via in tech.vias { selectedLayers.formUnion([via.bottomLayer, via.topLayer]) }
        for contact in tech.contacts { selectedLayers.formUnion([contact.bottomLayer, contact.topLayer]) }
        let known = Set(tech.layers.map(\.id))
        selectedLayers.formUnion([activeLayer, polyLayer].filter { known.contains($0) })
        // A technology with no configured device materials or layer bridges has
        // a metal-only profile, explicitly using its registered non-cut layers.
        if selectedLayers.isEmpty {
            selectedLayers = try LayoutConnectivityExtractor.productionConductiveLayers(tech, limits: limits)
            selectedLayers.subtract([nimpLayer, pimpLayer])
        }
        var replacements: [Int: [LayoutGeometry]] = [:]
        var slabRectsByActiveOrdinal: [Int: [LayoutRect?]] = [:]
        var preparedSlabCount = 0
        for (ordinal, active) in actives.enumerated() {
            if Task.isCancelled { throw LayoutConductorCaptureError.cancelled }
            guard let wrapped = channelsByActive[ordinal], let channels = wrapped, !channels.isEmpty else { continue }
            let horizontal = channels[0].horizontalCurrent
            var bounds = horizontal ? [active.rect.minX] : [active.rect.minY]
            for channel in channels {
                bounds.append(horizontal ? channel.rect.minX : channel.rect.minY)
                bounds.append(horizontal ? channel.rect.maxX : channel.rect.maxY)
            }
            bounds.append(horizontal ? active.rect.maxX : active.rect.maxY)
            var slabs: [LayoutRect?] = [], geometries: [LayoutGeometry] = []
            for index in 0...channels.count {
                let low = bounds[index * 2], high = bounds[index * 2 + 1]
                guard high - low > eps else { slabs.append(nil); continue }
                let slab = horizontal
                    ? LayoutRect(origin: .init(x: low, y: active.rect.minY), size: .init(width: high - low, height: active.rect.size.height))
                    : LayoutRect(origin: .init(x: active.rect.minX, y: low), size: .init(width: active.rect.size.width, height: high - low))
                guard preparedSlabCount < limits.maximumFootprints else { throw LayoutConductorCaptureError.limitExceeded(.footprints) }
                preparedSlabCount += 1
                slabs.append(slab)
                // The boundaries are the owner facts. Avoid admitting a new
                // high-minus-low span contaminated by translated subtraction.
                let minX = horizontal ? low : active.rect.minX
                let maxX = horizontal ? high : active.rect.maxX
                let minY = horizontal ? active.rect.minY : low
                let maxY = horizontal ? active.rect.maxY : high
                geometries.append(.polygon(.init(points: [
                    .init(x: minX, y: minY), .init(x: maxX, y: minY),
                    .init(x: maxX, y: maxY), .init(x: minX, y: maxY)])))
            }
            replacements[active.flatIndex] = geometries
            slabRectsByActiveOrdinal[ordinal] = slabs
        }
        return ConductorPreparation(layers: selectedLayers, replacements: replacements, slabs: slabRectsByActiveOrdinal)
    }

    private func capturePrepared(document: LayoutDocument, tech: LayoutTechDatabase, hierarchy: LayoutHierarchySnapshot,
        preparation: ConductorPreparation, limits: LayoutConductorCaptureLimits,
        electricalContext: LayoutElectricalContext = .deviceAwareMOS
    ) throws -> LayoutConductorSnapshot {
        var selected = Set(hierarchy.shapes.indices.map { LayoutConductorSnapshot.Source.shape($0) })
        selected.formUnion(hierarchy.vias.indices.map { .via($0) })
        for index in hierarchy.pins.indices where preparation.layers.contains(hierarchy.pins[index].layer) {
            selected.insert(.pin(index))
        }
        return try LayoutConnectivityExtractor().captureNativeConductors(document: document, tech: tech,
            conductiveLayers: preparation.layers, cellID: hierarchy.rootCellID, limits: limits, hierarchy: hierarchy,
            selectingSources: selected, replacingShapeGeometry: preparation.replacements, electricalContext: electricalContext).snapshot
    }

    private func occurrencePrefix(_ occurrence: LayoutHierarchySnapshot.Occurrence) -> String {
        "occurrence:" + occurrence.path.map { "\($0.instanceID.uuidString):\($0.row):\($0.column)" }.joined(separator: "/") + ":"
    }

    private func comparisonName(for reference: LayoutConductorSnapshot.NetReference?, fallback: String,
        names: [LayoutConductorSnapshot.NetReference: String], hierarchy: LayoutHierarchySnapshot, root: Int
    ) -> ComparisonNetID {
        guard let reference else { return ComparisonNetID("pin:\(fallback)") }
        if let name = names[reference] { return ComparisonNetID("pin:\(name)") }
        let scope = reference.occurrenceIndex == root ? "" : occurrencePrefix(hierarchy.occurrences[reference.occurrenceIndex])
        return ComparisonNetID("net:\(scope)\(reference.netID.uuidString)")
    }

    /// Labels of the cell plus all instance occurrences, recursively
    /// mapped into the target cell's space.
    private func flattenedLabels(hierarchy: LayoutHierarchySnapshot, document: LayoutDocument, root: Int) throws -> [LayoutLabel] {
        var result: [LayoutLabel] = []
        for (index, occurrence) in hierarchy.occurrences.enumerated() {
            guard let cell = document.cell(withID: occurrence.sourceCellID) else { throw LayoutHierarchyCaptureError.missingChildCell(occurrence.sourceCellID) }
            guard cell.labels.count <= LayoutHierarchyCaptureLimits.default.maximumObjects - result.count else {
                throw LayoutHierarchyCaptureError.limitExceeded(.objects)
            }
            for label in cell.labels {
                var transformed = label
                for transform in occurrence.transforms.reversed() { transformed.position = transform.apply(to: transformed.position) }
                if index != root { transformed.text = occurrencePrefix(occurrence) + transformed.text }
                result.append(transformed)
            }
        }
        return result
    }

    /// Label → island, by point containment in member geometry on the
    /// label's layer. A label floating off its layer's conductors names
    /// nothing (instance banners, annotations). Lowest island index wins
    /// deterministically; labels per island sort by text.
    private func mapLabelsToIslands(
        labels: [LayoutLabel],
        connectivity: Connectivity
    ) -> [Int: [LayoutLabel]] {
        var result: [Int: [LayoutLabel]] = [:]
        for label in labels {
            var island: Int? = nil
            for element in connectivity.elements.values {
                guard element.layer == label.layer,
                      let candidate = connectivity.islandIndexByKey[element.key],
                      island.map({ candidate < $0 }) ?? true,
                      LayoutGeometryAnalysis.contains(label.position, in: element.geometry) else {
                    continue
                }
                island = candidate
            }
            if let island {
                result[island, default: []].append(label)
            }
        }
        for island in result.keys {
            result[island]?.sort { $0.text < $1.text }
        }
        return result
    }

    /// Pin flatten-index → island, by geometric overlap on the pin's
    /// layer. Pins touching several islands take the lowest index, which
    /// is deterministic; pins touching none stay unmapped.
    private func mapPinsToIslands(
        pins: [LayoutPin],
        connectivity: Connectivity
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for pin in connectivity.snapshot.pins {
            if let island = pin.componentIndices.first { result[pin.sourcePinIndex] = island }
        }
        return result
    }

    /// Stable comparison name per island. Precedence: a unique declared
    /// net, then a pin sitting on the island, then a label sitting on
    /// member conductor, then a deterministic anonymous ordinal that can
    /// never match a named reference net.
    private func nameIslands(
        connectivity: Connectivity,
        pins: [LayoutPin],
        pinIslandByIndex: [Int: Int],
        labelsByIsland: [Int: [LayoutLabel]],
        netNameByID: [LayoutConductorSnapshot.NetReference: String],
        issues: inout [DeviceExtractionIssue]
    ) -> [ComparisonNetID] {
        var pinsByIsland: [Int: [Int]] = [:]
        for (pinIndex, island) in pinIslandByIndex {
            pinsByIsland[island, default: []].append(pinIndex)
        }
        for island in pinsByIsland.keys {
            pinsByIsland[island]?.sort { pins[$0].name < pins[$1].name }
        }

        var names: [ComparisonNetID] = []
        names.reserveCapacity(connectivity.islandCount)
        var usedNames: [ComparisonNetID: Int] = [:]
        for island in 0..<connectivity.islandCount {
            let declared = connectivity.declaredNetsByIsland[island] ?? []
            if declared.count > 1 {
                issues.append(DeviceExtractionIssue(
                    kind: .shortedNet,
                    message: "One connected island carries \(declared.count) declared nets.",
                    region: islandBounds(island, connectivity: connectivity) ?? .zero,
                    shapeIDs: islandShapeIDs(island, connectivity: connectivity),
                    affectedLayers: islandLayers(island, connectivity: connectivity),
                    policyApplicability: .layoutRepairRequired,
                    suggestedActions: ["split-shorted-conductors", "inspect-net-annotations"]
                ))
            }
            let base: ComparisonNetID
            let root = connectivity.root
            if let first = declared.first {
                base = comparisonName(for: first, fallback: "", names: netNameByID, hierarchy: connectivity.snapshot.hierarchy, root: root)
            } else if let pinIndex = pinsByIsland[island]?.first {
                base = comparisonName(for: connectivity.snapshot.declaredNetBySource[.pin(pinIndex)], fallback: pins[pinIndex].name,
                    names: netNameByID, hierarchy: connectivity.snapshot.hierarchy, root: root)
            } else if let label = labelsByIsland[island]?.first {
                base = ComparisonNetID("pin:\(label.text)")
            } else {
                base = ComparisonNetID("island:\(island)")
            }
            // Two disconnected islands must never share a comparison name:
            // that would silently merge an open net. The first island keeps
            // the name, later ones are disambiguated and reported.
            if let priorUses = usedNames[base] {
                issues.append(DeviceExtractionIssue(
                    kind: .openNet,
                    message: "Net '\(base.rawValue)' spans \(priorUses + 1) disconnected islands.",
                    region: islandBounds(island, connectivity: connectivity) ?? .zero,
                    shapeIDs: islandShapeIDs(island, connectivity: connectivity),
                    affectedNet: base,
                    affectedLayers: islandLayers(island, connectivity: connectivity),
                    policyApplicability: .layoutRepairRequired,
                    suggestedActions: ["connect-open-net", "inspect-net-annotations"]
                ))
                usedNames[base] = priorUses + 1
                names.append(ComparisonNetID("island:\(island):open:\(base.rawValue)"))
            } else {
                usedNames[base] = 1
                names.append(base)
            }
        }
        return names
    }

    private func islandBounds(_ island: Int, connectivity: Connectivity) -> LayoutRect? {
        connectivity.elements.values
            .filter { connectivity.islandIndexByKey[$0.key] == island }
            .map(\.boundingBox)
            .reduce(nil as LayoutRect?) { partial, box in
                partial.map { $0.union(box) } ?? box
            }
    }

    private func islandShapeIDs(_ island: Int, connectivity: Connectivity) -> [UUID] {
        connectivity.elements.values
            .filter { connectivity.islandIndexByKey[$0.key] == island }
            .map(\.elementID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func islandLayers(_ island: Int, connectivity: Connectivity) -> [LayoutLayerID] {
        var layers = Set<LayoutLayerID>()
        for element in connectivity.elements.values where connectivity.islandIndexByKey[element.key] == island {
            if let layer = element.layer {
                layers.insert(layer)
            }
            if let viaDefinition = element.viaDefinition {
                layers.insert(viaDefinition.cutLayer)
                layers.insert(viaDefinition.topLayer)
                layers.insert(viaDefinition.bottomLayer)
            }
        }
        return layers.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.purpose < $1.purpose
        }
    }

    // MARK: - Device assembly

    private func recognizeDevices(
        shapes: [LayoutShape],
        actives: [Active],
        channelsByActive: [Int: [Channel]?],
        connectivity: Connectivity,
        islandNames: [ComparisonNetID],
        pins: [LayoutPin],
        pinIslandByIndex: [Int: Int],
        fallbackPinNames: [Int: ComparisonNetID],
        issues: inout [DeviceExtractionIssue]
    ) -> [ComparisonNetlist.Device] {
        let nimpBoxes = shapes
            .filter { $0.layer == nimpLayer }
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }
        let pimpBoxes = shapes
            .filter { $0.layer == pimpLayer }
            .map { LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }

        func islandName(of key: ConnectivityElementKey?) -> ComparisonNetID? {
            guard let key, let island = connectivity.islandIndexByKey[key] else { return nil }
            return islandNames[island]
        }

        // Channel-less actives are substrate/well taps; their conductor
        // island is the rail the bulk actually ties to. They back up the
        // bulk-pin resolution when no pins exist (post-GDS documents).
        var tapCandidates: [(rect: LayoutRect, name: ComparisonNetID, isPType: Bool)] = []
        for (ordinal, active) in actives.enumerated() {
            if let maybeChannels = channelsByActive[ordinal],
               let channels = maybeChannels,
               !channels.isEmpty {
                continue
            }
            guard let name = islandName(of: connectivity.plainShapeKeyByFlatIndex[active.flatIndex]) else {
                continue
            }
            let nimp = nimpBoxes.contains { positiveIntersection($0, active.rect) != nil }
            let pimp = pimpBoxes.contains { positiveIntersection($0, active.rect) != nil }
            guard nimp != pimp else { continue }
            tapCandidates.append((rect: active.rect, name: name, isPType: pimp))
        }

        var devices: [ComparisonNetlist.Device] = []
        for (activeOrdinal, active) in actives.enumerated() {
            guard let maybeChannels = channelsByActive[activeOrdinal],
                  let channels = maybeChannels,
                  !channels.isEmpty,
                  let slabKeys = connectivity.slabKeysByActiveOrdinal[activeOrdinal] else {
                continue
            }
            for (channelOrdinal, channel) in channels.enumerated() {
                let nimp = nimpBoxes.contains { positiveIntersection($0, channel.rect) != nil }
                let pimp = pimpBoxes.contains { positiveIntersection($0, channel.rect) != nil }
                let kind: ComparisonDeviceKind
                switch (nimp, pimp) {
                case (true, false):
                    kind = .nmos
                case (false, true):
                    kind = .pmos
                default:
                    issues.append(DeviceExtractionIssue(
                        kind: .ambiguousDeviceType,
                        message: "Channel overlaps neither or both MOS implants.",
                        region: channel.rect,
                        shapeIDs: [shapes[active.flatIndex].id, shapes[channel.polyFlatIndex].id],
                        affectedLayers: [activeLayer, nimpLayer, pimpLayer, polyLayer],
                        policyApplicability: .layerMappingReviewRequired,
                        suggestedActions: [
                            "fix-implant-coverage",
                            "inspect-layer-mapping",
                            "review-device-extraction-profile"
                        ]
                    ))
                    continue
                }

                func terminalNet(
                    slabOrdinal: Int,
                    role: ComparisonTerminalRole
                ) -> ComparisonNetID {
                    if slabOrdinal < slabKeys.count, let name = islandName(of: slabKeys[slabOrdinal]) {
                        return name
                    }
                    let side = role == .source ? "low" : "high"
                    issues.append(DeviceExtractionIssue(
                        kind: .missingTerminal,
                        message: "Channel has no \(role.rawValue) diffusion on its \(side) side.",
                        region: channel.rect,
                        shapeIDs: [shapes[active.flatIndex].id],
                        affectedDeviceKind: kind,
                        affectedTerminal: role,
                        affectedLayers: [activeLayer],
                        policyApplicability: .layoutRepairRequired,
                        suggestedActions: ["repair-terminal-diffusion", "inspect-contact-coverage"]
                    ))
                    return ComparisonNetID("unconnected:\(active.flatIndex):\(channelOrdinal):\(role.rawValue)")
                }

                guard let gate = islandName(of: connectivity.polyKeyByFlatIndex[channel.polyFlatIndex]) else {
                    issues.append(DeviceExtractionIssue(
                        kind: .missingTerminal,
                        message: "Gate poly is missing from the connectivity table.",
                        region: channel.rect,
                        shapeIDs: [shapes[channel.polyFlatIndex].id],
                        affectedDeviceKind: kind,
                        affectedTerminal: .gate,
                        affectedLayers: [polyLayer],
                        policyApplicability: .layoutRepairRequired,
                        suggestedActions: ["repair-gate-poly-connectivity", "inspect-contact-coverage"]
                    ))
                    continue
                }
                let source = terminalNet(slabOrdinal: channelOrdinal, role: .source)
                let drain = terminalNet(slabOrdinal: channelOrdinal + 1, role: .drain)
                let bulk = bulkTerminalNet(
                    activeRect: active.rect,
                    deviceKind: kind,
                    pins: pins,
                    pinIslandByIndex: pinIslandByIndex,
                    islandNames: islandNames,
                    // NMOS bulk is the substrate (P+ tap), PMOS the well (N+ tap).
                    taps: tapCandidates.filter { $0.isPType == (kind == .nmos) },
                    fallbackPinNames: fallbackPinNames,
                    issues: &issues
                )

                let width = channel.horizontalCurrent
                    ? channel.rect.size.height
                    : channel.rect.size.width
                let length = channel.horizontalCurrent
                    ? channel.rect.size.width
                    : channel.rect.size.height
                devices.append(ComparisonNetlist.Device(
                    id: "device:\(active.flatIndex):\(channel.polyFlatIndex)",
                    kind: kind,
                    terminals: [
                        .gate: gate,
                        .source: source,
                        .drain: drain,
                        .bulk: bulk,
                    ],
                    parameters: ComparisonDeviceParameters(width: width, length: length),
                    region: channel.rect
                ))
            }
        }
        return devices
    }

    /// Substrate/well connectivity is not part of the drawn conductor
    /// stack, so bulk anchors on the nearest bulk-role pin — but resolves
    /// to that pin's ISLAND name when the pin sits on wired geometry, so
    /// a tap strapped to a named rail reads as that rail. Without any
    /// bulk pin (pins do not survive GDS), the nearest matching-polarity
    /// tap's island answers instead — that diffusion IS the bulk tie.
    private func bulkTerminalNet(
        activeRect: LayoutRect,
        deviceKind: ComparisonDeviceKind,
        pins: [LayoutPin],
        pinIslandByIndex: [Int: Int],
        islandNames: [ComparisonNetID],
        taps: [(rect: LayoutRect, name: ComparisonNetID, isPType: Bool)],
        fallbackPinNames: [Int: ComparisonNetID],
        issues: inout [DeviceExtractionIssue]
    ) -> ComparisonNetID {
        func rectDistance(_ lhs: LayoutRect, _ rhs: LayoutRect) -> Double {
            let dx = max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX, 0)
            let dy = max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY, 0)
            return dx * dx + dy * dy
        }
        let candidates = pins.enumerated().filter { $0.element.role == .bulk }
        guard let best = candidates.min(by: {
            pinDistance($0.element, to: activeRect) < pinDistance($1.element, to: activeRect)
        }) else {
            if let tap = taps.min(by: {
                rectDistance($0.rect, activeRect) < rectDistance($1.rect, activeRect)
            }) {
                return tap.name
            }
            issues.append(DeviceExtractionIssue(
                kind: .missingTerminal,
                message: "No bulk pin or tap was available for device terminal extraction.",
                region: activeRect,
                affectedDeviceKind: deviceKind,
                affectedTerminal: .bulk,
                affectedLayers: [activeLayer, nimpLayer, pimpLayer],
                policyApplicability: .layoutRepairRequired,
                suggestedActions: ["add-bulk-tap", "inspect-bulk-pin-or-tap"]
            ))
            return ComparisonNetID("bulk:default")
        }
        if let island = pinIslandByIndex[best.offset] {
            return islandNames[island]
        }
        return fallbackPinNames[best.offset] ?? ComparisonNetID("unconnected:bulk:\(best.offset)")
    }

    // MARK: - Grouping

    private struct DeviceGroupKey: Hashable {
        var kind: ComparisonDeviceKind
        var gate: ComparisonNetID?
        var sourceDrain: [ComparisonNetID]
        var bulk: ComparisonNetID?
        var widthKey: Int64
        var lengthKey: Int64
    }

    private func groupedDevices(
        _ devices: [ComparisonNetlist.Device]
    ) -> [ComparisonNetlist.Device] {
        var groups: [DeviceGroupKey: ComparisonNetlist.Device] = [:]
        var order: [DeviceGroupKey] = []
        for device in devices {
            let key = DeviceGroupKey(
                kind: device.kind,
                gate: device.terminals[.gate],
                sourceDrain: [device.terminals[.source], device.terminals[.drain]]
                    .compactMap { $0 }
                    .sorted(),
                bulk: device.terminals[.bulk],
                widthKey: parameterKey(device.parameters.width),
                lengthKey: parameterKey(device.parameters.length)
            )
            if groups[key] == nil {
                order.append(key)
                groups[key] = device
            } else if var grouped = groups[key] {
                grouped.id += "+\(device.id)"
                grouped.parameters.multiplier += device.parameters.multiplier
                grouped.region = grouped.region.union(device.region)
                groups[key] = grouped
            }
        }
        return order.compactMap { groups[$0] }
    }

    private func parameterKey(_ value: Double) -> Int64 {
        Int64((value / 1e-9).rounded())
    }

    // MARK: - Ports

    /// Ports resolve through the island under each pin, so a port name
    /// follows the wiring it actually touches. Duplicate pin names are
    /// legal when they agree on the net; a disagreement is reported and
    /// the first (flatten-order) resolution wins deterministically.
    private func ports(
        from pins: [LayoutPin], rootPinRange: Range<Int>,
        pinIslandByIndex: [Int: Int],
        labelsByIsland: [Int: [LayoutLabel]],
        declaredNetsByIsland: [Int: [LayoutConductorSnapshot.NetReference]],
        netNameByID: [LayoutConductorSnapshot.NetReference: String],
        islandNames: [ComparisonNetID],
        connectivity: Connectivity,
        root: Int,
        issues: inout [DeviceExtractionIssue]
    ) -> [String: ComparisonNetID] {
        var ports: [String: ComparisonNetID] = [:]
        func insertPort(name: String, net: ComparisonNetID, region: LayoutRect) {
            if let existing = ports[name] {
                if existing != net {
                    issues.append(DeviceExtractionIssue(
                        kind: .conflictingPort,
                        message: "Port '\(name)' resolves to both \(existing.rawValue) and \(net.rawValue).",
                        region: region,
                        affectedNet: net,
                        policyApplicability: .netAnnotationRequired,
                        suggestedActions: ["deduplicate-port-labels", "inspect-net-annotations"]
                    ))
                }
            } else {
                ports[name] = net
            }
        }

        for pinIndex in rootPinRange {
            let pin = pins[pinIndex]
            let net: ComparisonNetID
            if let island = pinIslandByIndex[pinIndex] {
                net = islandNames[island]
            } else {
                net = comparisonName(for: connectivity.snapshot.declaredNetBySource[.pin(pinIndex)], fallback: pin.name,
                    names: netNameByID, hierarchy: connectivity.snapshot.hierarchy, root: root)
            }
            insertPort(name: pin.name, net: net, region: pinRect(pin))
        }

        for island in 0..<connectivity.islandCount {
            let net = islandNames[island]
            let region = islandBounds(island, connectivity: connectivity) ?? .zero
            for label in labelsByIsland[island] ?? [] {
                insertPort(name: label.text, net: net, region: region)
            }
            for netID in declaredNetsByIsland[island] ?? [] where netID.occurrenceIndex == root {
                if let name = netNameByID[netID] {
                    insertPort(name: name, net: net, region: region)
                }
            }
        }
        return ports
    }

    // MARK: - Shared helpers

    private func positiveIntersection(_ lhs: LayoutRect, _ rhs: LayoutRect) -> LayoutRect? {
        let minX = max(lhs.minX, rhs.minX)
        let minY = max(lhs.minY, rhs.minY)
        let maxX = min(lhs.maxX, rhs.maxX)
        let maxY = min(lhs.maxY, rhs.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func pinRect(_ pin: LayoutPin) -> LayoutRect {
        LayoutRect(
            origin: LayoutPoint(
                x: pin.position.x - pin.size.width / 2,
                y: pin.position.y - pin.size.height / 2
            ),
            size: pin.size
        )
    }

    private func pinDistance(_ pin: LayoutPin, to rect: LayoutRect) -> Double {
        let box = pinRect(pin)
        if box.intersects(rect) { return 0 }
        let dx = max(rect.minX - box.maxX, box.minX - rect.maxX, 0)
        let dy = max(rect.minY - box.maxY, box.minY - rect.maxY, 0)
        return dx * dx + dy * dy
    }
}
