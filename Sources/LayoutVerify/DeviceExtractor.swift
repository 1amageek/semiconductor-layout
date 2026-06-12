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

        var shapes: [LayoutShape] = []
        var vias: [LayoutVia] = []
        var pins: [LayoutPin] = []
        var conflicts: [LayoutDRCService.TerminalConnectivityConflict] = []
        service.flatten(
            cell: targetCell,
            document: document,
            tech: tech,
            transforms: [],
            terminalNetIDs: [:],
            shapes: &shapes,
            vias: &vias,
            pins: &pins,
            terminalConflicts: &conflicts
        )

        var issues: [DeviceExtractionIssue] = []

        let actives = recognizeActives(shapes: shapes, issues: &issues)
        let channelsByActive = discoverChannels(
            shapes: shapes,
            actives: actives,
            issues: &issues
        )
        let connectivity = buildConnectivity(
            shapes: shapes,
            vias: vias,
            actives: actives,
            channelsByActive: channelsByActive,
            tech: tech,
            service: service
        )
        let pinIslandByIndex = mapPinsToIslands(pins: pins, connectivity: connectivity)
        let islandNames = nameIslands(
            connectivity: connectivity,
            pins: pins,
            pinIslandByIndex: pinIslandByIndex,
            issues: &issues
        )

        var devices = recognizeDevices(
            shapes: shapes,
            actives: actives,
            channelsByActive: channelsByActive,
            connectivity: connectivity,
            islandNames: islandNames,
            pins: pins,
            issues: &issues
        )
        devices = groupedDevices(devices)
        devices.sort {
            if $0.region.minX != $1.region.minX { return $0.region.minX < $1.region.minX }
            if $0.region.minY != $1.region.minY { return $0.region.minY < $1.region.minY }
            return $0.id < $1.id
        }

        let ports = ports(
            from: pins,
            pinIslandByIndex: pinIslandByIndex,
            islandNames: islandNames,
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
                    shapeIDs: [shape.id]
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
        issues: inout [DeviceExtractionIssue]
    ) -> [Int: [Channel]?] {
        var result: [Int: [Channel]?] = [:]
        for (activeOrdinal, active) in actives.enumerated() {
            var channels: [Channel] = []
            var invalid = false
            for (index, shape) in shapes.enumerated() where shape.layer == polyLayer {
                guard let polyRect = rectLike(shape.geometry) else { continue }
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
                        shapeIDs: [shapes[active.flatIndex].id, shape.id]
                    ))
                    invalid = true
                case (false, false):
                    issues.append(DeviceExtractionIssue(
                        kind: .unrecognizedChannel,
                        message: "POLY only partially crosses ACTIVE; the channel is not a full crossing.",
                        region: channel,
                        shapeIDs: [shapes[active.flatIndex].id, shape.id]
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
                    shapeIDs: [shapes[active.flatIndex].id]
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
                    shapeIDs: [shapes[active.flatIndex].id]
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
        var declaredNetsByIsland: [Int: [UUID]]
        var islandCount: Int
        /// Element key of each poly shape, by flatten index.
        var polyKeyByFlatIndex: [Int: ConnectivityElementKey]
        /// Slab element keys per active ordinal, in channel order:
        /// slab k sits before channel k, slab k+1 after it. `nil` entries
        /// are zero-width gaps (channel at the active edge).
        var slabKeysByActiveOrdinal: [Int: [ConnectivityElementKey?]]
        var slabRectsByActiveOrdinal: [Int: [LayoutRect?]]
    }

    /// Builds the conductor element table the way the device sees it:
    /// channel-bearing actives are replaced by their source/drain slabs,
    /// contact-cut shapes become layer bridges like vias, everything else
    /// conducts within its own layer. Keys are deterministic flatten-order
    /// ordinals, so two extractions of the same document agree exactly.
    private func buildConnectivity(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        actives: [Active],
        channelsByActive: [Int: [Channel]?],
        tech: LayoutTechDatabase,
        service: LayoutDRCService
    ) -> Connectivity {
        let contactCutLayers = Set(tech.contacts.map(\.cutLayer))
        let activeOrdinalByFlatIndex = Dictionary(
            uniqueKeysWithValues: actives.enumerated().map { ($0.element.flatIndex, $0.offset) }
        )

        var elements: [ConnectivityElementKey: ConnectivityElement] = [:]
        var polyKeyByFlatIndex: [Int: ConnectivityElementKey] = [:]
        var slabKeysByActiveOrdinal: [Int: [ConnectivityElementKey?]] = [:]
        var slabRectsByActiveOrdinal: [Int: [LayoutRect?]] = [:]
        var shapeOrdinal = 0
        var viaOrdinal = 0

        func appendShapeElement(_ shape: LayoutShape, geometry: LayoutGeometry) -> ConnectivityElementKey {
            let key = ConnectivityElementKey.shape(.child(shapeOrdinal))
            shapeOrdinal += 1
            elements[key] = ConnectivityElement(
                key: key,
                elementID: shape.id,
                isVia: false,
                netID: shape.netID,
                geometry: geometry,
                layer: shape.layer,
                viaDefinition: nil,
                boundingBox: LayoutGeometryAnalysis.boundingBox(for: geometry)
            )
            return key
        }

        for (index, shape) in shapes.enumerated() {
            if shape.layer == polyLayer {
                polyKeyByFlatIndex[index] = appendShapeElement(shape, geometry: shape.geometry)
                continue
            }
            if contactCutLayers.contains(shape.layer) {
                // A contact cut conducts between its definition's bottom
                // and top layers, exactly like a via plug. Definitions
                // sharing the cut layer (active vs poly contact) each get
                // a bridge element; a bridge whose far layer is absent
                // under the cut simply joins nothing there.
                let definitions = tech.contacts
                    .filter { $0.cutLayer == shape.layer }
                    .sorted { $0.id < $1.id }
                for definition in definitions {
                    let key = ConnectivityElementKey.via(.child(viaOrdinal))
                    viaOrdinal += 1
                    elements[key] = ConnectivityElement(
                        key: key,
                        elementID: shape.id,
                        isVia: true,
                        netID: shape.netID,
                        geometry: shape.geometry,
                        layer: nil,
                        viaDefinition: LayoutViaDefinition(
                            id: definition.id,
                            cutLayer: definition.cutLayer,
                            topLayer: definition.topLayer,
                            bottomLayer: definition.bottomLayer,
                            cutSize: definition.cutSize,
                            enclosure: definition.enclosure,
                            cutSpacing: definition.cutSpacing
                        ),
                        boundingBox: LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
                    )
                }
                continue
            }
            if let activeOrdinal = activeOrdinalByFlatIndex[index],
               let maybeChannels = channelsByActive[activeOrdinal],
               let channels = maybeChannels,
               !channels.isEmpty {
                let active = actives[activeOrdinal]
                let horizontal = channels[0].horizontalCurrent
                var boundaries: [Double] = horizontal ? [active.rect.minX] : [active.rect.minY]
                for channel in channels {
                    boundaries.append(horizontal ? channel.rect.minX : channel.rect.minY)
                    boundaries.append(horizontal ? channel.rect.maxX : channel.rect.maxY)
                }
                boundaries.append(horizontal ? active.rect.maxX : active.rect.maxY)

                var slabKeys: [ConnectivityElementKey?] = []
                var slabRects: [LayoutRect?] = []
                for slabIndex in 0...(channels.count) {
                    let low = boundaries[slabIndex * 2]
                    let high = boundaries[slabIndex * 2 + 1]
                    guard high - low > eps else {
                        slabKeys.append(nil)
                        slabRects.append(nil)
                        continue
                    }
                    let rect = horizontal
                        ? LayoutRect(
                            origin: LayoutPoint(x: low, y: active.rect.minY),
                            size: LayoutSize(width: high - low, height: active.rect.size.height)
                        )
                        : LayoutRect(
                            origin: LayoutPoint(x: active.rect.minX, y: low),
                            size: LayoutSize(width: active.rect.size.width, height: high - low)
                        )
                    slabKeys.append(appendShapeElement(shape, geometry: .rect(rect)))
                    slabRects.append(rect)
                }
                slabKeysByActiveOrdinal[activeOrdinal] = slabKeys
                slabRectsByActiveOrdinal[activeOrdinal] = slabRects
                continue
            }
            _ = appendShapeElement(shape, geometry: shape.geometry)
        }

        for via in vias {
            let key = ConnectivityElementKey.via(.child(viaOrdinal))
            viaOrdinal += 1
            let cut = service.viaCutRect(for: via, tech: tech)
            elements[key] = ConnectivityElement(
                key: key,
                elementID: via.id,
                isVia: true,
                netID: via.netID,
                geometry: .rect(cut),
                layer: nil,
                viaDefinition: tech.viaDefinition(for: via.viaDefinitionID),
                boundingBox: cut
            )
        }

        let adjacency = LayoutConnectivityExtractor.contactAdjacency(
            elements: elements,
            service: service
        )
        let components = LayoutConnectivityExtractor.components(
            adjacency: adjacency,
            elements: elements
        )

        var islandIndexByKey: [ConnectivityElementKey: Int] = [:]
        var declaredNetsByIsland: [Int: [UUID]] = [:]
        for (islandIndex, component) in components.enumerated() {
            var declared = Set<UUID>()
            for key in component {
                islandIndexByKey[key] = islandIndex
                if let netID = elements[key]?.netID {
                    declared.insert(netID)
                }
            }
            declaredNetsByIsland[islandIndex] = declared.sorted { $0.uuidString < $1.uuidString }
        }

        return Connectivity(
            islandIndexByKey: islandIndexByKey,
            elements: elements,
            declaredNetsByIsland: declaredNetsByIsland,
            islandCount: components.count,
            polyKeyByFlatIndex: polyKeyByFlatIndex,
            slabKeysByActiveOrdinal: slabKeysByActiveOrdinal,
            slabRectsByActiveOrdinal: slabRectsByActiveOrdinal
        )
    }

    /// Pin flatten-index → island, by geometric overlap on the pin's
    /// layer. Pins touching several islands take the lowest index, which
    /// is deterministic; pins touching none stay unmapped.
    private func mapPinsToIslands(
        pins: [LayoutPin],
        connectivity: Connectivity
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (pinIndex, pin) in pins.enumerated() {
            let probe = LayoutGeometry.rect(pinRect(pin))
            var island: Int? = nil
            for element in connectivity.elements.values {
                guard element.layer == pin.layer,
                      let candidate = connectivity.islandIndexByKey[element.key],
                      island.map({ candidate < $0 }) ?? true,
                      LayoutGeometryAnalysis.intersects(probe, element.geometry) else {
                    continue
                }
                island = candidate
            }
            if let island {
                result[pinIndex] = island
            }
        }
        return result
    }

    /// Stable comparison name per island. Precedence: a unique declared
    /// net, then a pin sitting on the island, then a deterministic
    /// anonymous ordinal that can never match a named reference net.
    private func nameIslands(
        connectivity: Connectivity,
        pins: [LayoutPin],
        pinIslandByIndex: [Int: Int],
        issues: inout [DeviceExtractionIssue]
    ) -> [ComparisonNetID] {
        var pinsByIsland: [Int: [LayoutPin]] = [:]
        for (pinIndex, island) in pinIslandByIndex {
            pinsByIsland[island, default: []].append(pins[pinIndex])
        }
        for island in pinsByIsland.keys {
            pinsByIsland[island]?.sort { $0.name < $1.name }
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
                    region: islandBounds(island, connectivity: connectivity) ?? .zero
                ))
            }
            let base: ComparisonNetID
            if let first = declared.first {
                base = ComparisonNetID("net:\(first.uuidString)")
            } else if let pin = pinsByIsland[island]?.first {
                if let netID = pin.netID {
                    base = ComparisonNetID("net:\(netID.uuidString)")
                } else {
                    base = ComparisonNetID("pin:\(pin.name)")
                }
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
                    region: islandBounds(island, connectivity: connectivity) ?? .zero
                ))
                usedNames[base] = priorUses + 1
                names.append(ComparisonNetID("\(base.rawValue):split:\(priorUses)"))
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

    // MARK: - Device assembly

    private func recognizeDevices(
        shapes: [LayoutShape],
        actives: [Active],
        channelsByActive: [Int: [Channel]?],
        connectivity: Connectivity,
        islandNames: [ComparisonNetID],
        pins: [LayoutPin],
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
                        shapeIDs: [shapes[active.flatIndex].id, shapes[channel.polyFlatIndex].id]
                    ))
                    continue
                }

                func terminalNet(
                    slabOrdinal: Int,
                    role: String
                ) -> ComparisonNetID {
                    if slabOrdinal < slabKeys.count, let name = islandName(of: slabKeys[slabOrdinal]) {
                        return name
                    }
                    issues.append(DeviceExtractionIssue(
                        kind: .missingTerminal,
                        message: "Channel has no \(role) diffusion on its \(role == "source" ? "low" : "high") side.",
                        region: channel.rect,
                        shapeIDs: [shapes[active.flatIndex].id]
                    ))
                    return ComparisonNetID("unconnected:\(active.flatIndex):\(channelOrdinal):\(role)")
                }

                guard let gate = islandName(of: connectivity.polyKeyByFlatIndex[channel.polyFlatIndex]) else {
                    issues.append(DeviceExtractionIssue(
                        kind: .missingTerminal,
                        message: "Gate poly is missing from the connectivity table.",
                        region: channel.rect,
                        shapeIDs: [shapes[channel.polyFlatIndex].id]
                    ))
                    continue
                }
                let source = terminalNet(slabOrdinal: channelOrdinal, role: "source")
                let drain = terminalNet(slabOrdinal: channelOrdinal + 1, role: "drain")
                let bulk = bulkTerminalNet(
                    activeRect: active.rect,
                    pins: pins,
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
    /// stack, so bulk keeps the nearest-pin resolution with an explicit
    /// issue when no bulk-role pin exists.
    private func bulkTerminalNet(
        activeRect: LayoutRect,
        pins: [LayoutPin],
        issues: inout [DeviceExtractionIssue]
    ) -> ComparisonNetID {
        let candidates = pins.filter { $0.role == .bulk }
        guard let best = candidates.min(by: {
            pinDistance($0, to: activeRect) < pinDistance($1, to: activeRect)
        }) else {
            issues.append(DeviceExtractionIssue(
                kind: .missingTerminal,
                message: "No bulk pin was available for device terminal extraction.",
                region: activeRect
            ))
            return ComparisonNetID("bulk:default")
        }
        if let netID = best.netID {
            return ComparisonNetID("net:\(netID.uuidString)")
        }
        return ComparisonNetID("pin:\(best.name)")
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
            } else {
                var grouped = groups[key]!
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
        from pins: [LayoutPin],
        pinIslandByIndex: [Int: Int],
        islandNames: [ComparisonNetID],
        issues: inout [DeviceExtractionIssue]
    ) -> [String: ComparisonNetID] {
        var ports: [String: ComparisonNetID] = [:]
        for (pinIndex, pin) in pins.enumerated() {
            let net: ComparisonNetID
            if let island = pinIslandByIndex[pinIndex] {
                net = islandNames[island]
            } else if let netID = pin.netID {
                net = ComparisonNetID("net:\(netID.uuidString)")
            } else {
                net = ComparisonNetID("pin:\(pin.name)")
            }
            if let existing = ports[pin.name] {
                if existing != net {
                    issues.append(DeviceExtractionIssue(
                        kind: .conflictingPort,
                        message: "Port '\(pin.name)' resolves to both \(existing.rawValue) and \(net.rawValue).",
                        region: pinRect(pin)
                    ))
                }
            } else {
                ports[pin.name] = net
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
