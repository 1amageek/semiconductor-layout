import Foundation
import CryptoKit
import LayoutCore
import LayoutTech

public struct LayoutGeometryExtractor: LayoutGeometryExtracting {
    private let epsilon = 1e-9

    public init() {}

    public func extract(
        document: LayoutDocument,
        technology: LayoutTechDatabase,
        topCellID: UUID? = nil,
        profile: LayoutExtractionProcessProfile,
        maximumObjectCount: Int = 2_000_000
    ) throws -> LayoutExtractionIR {
        let resolvedTopCellID = topCellID ?? document.topCellID
        guard let resolvedTopCellID,
              let topCell = document.cell(withID: resolvedTopCellID) else {
            throw LayoutGeometryExtractionError.topCellNotFound
        }
        var flattened = FlattenedLayout(topCellName: topCell.name)
        try flatten(
            cell: topCell,
            document: document,
            path: [topCell.name],
            transforms: [],
            activeCellIDs: [],
            topLevel: true,
            maximumObjectCount: maximumObjectCount,
            output: &flattened
        )
        return buildIR(
            from: flattened,
            technology: technology,
            profile: profile,
            maximumObjectCount: maximumObjectCount
        )
    }

    private struct FlatShape: Sendable {
        let objectID: LayoutExtractionObjectID
        let sourceShapeID: String
        let occurrenceID: LayoutExtractionObjectID
        let layer: LayoutLayerID
        let geometry: LayoutGeometry
    }

    private struct FlatLabel: Sendable {
        let name: String
        let point: LayoutPoint
        let layer: LayoutLayerID
        let topLevel: Bool
    }

    private struct FlatVia: Sendable {
        let objectID: LayoutExtractionObjectID
        let sourceViaID: String
        let occurrenceID: LayoutExtractionObjectID
        let definitionID: String
        let point: LayoutPoint
    }

    private struct FlatPin: Sendable {
        let name: String
        let point: LayoutPoint
        let layer: LayoutLayerID
        let topLevel: Bool
    }

    private struct FlattenedLayout: Sendable {
        let topCellName: String
        var shapes: [FlatShape] = []
        var vias: [FlatVia] = []
        var labels: [FlatLabel] = []
        var pins: [FlatPin] = []
        var occurrences: [LayoutExtractionOccurrence] = []
    }

    private func flatten(
        cell: LayoutCell,
        document: LayoutDocument,
        path: [String],
        transforms: [LayoutTransform],
        activeCellIDs: Set<UUID>,
        topLevel: Bool,
        maximumObjectCount: Int,
        output: inout FlattenedLayout
    ) throws {
        guard !activeCellIDs.contains(cell.id) else {
            throw LayoutGeometryExtractionError.recursiveHierarchy(path.joined(separator: "/"))
        }
        var nextActiveCellIDs = activeCellIDs
        nextActiveCellIDs.insert(cell.id)
        let occurrenceID = LayoutExtractionObjectID(rawValue: "occurrence:/\(path.joined(separator: "/"))")
        output.occurrences.append(LayoutExtractionOccurrence(
            objectID: occurrenceID,
            cellName: cell.name,
            hierarchyPath: path,
            sourceObjectID: "cell:/\(path.joined(separator: "/"))",
            transformDescription: transformDescription(transforms)
        ))
        let orderedShapes = cell.shapes.enumerated().sorted {
            let lhsKey = shapeOrderKey($0.element)
            let rhsKey = shapeOrderKey($1.element)
            return lhsKey == rhsKey ? $0.offset < $1.offset : lhsKey < rhsKey
        }
        for (shapeIndex, indexedShape) in orderedShapes.enumerated() {
            let shape = indexedShape.element
            let stableSourceID = "shape:/\(path.joined(separator: "/"))/#\(shapeIndex)"
            let objectID = LayoutExtractionObjectID(
                rawValue: stableSourceID
            )
            output.shapes.append(FlatShape(
                objectID: objectID,
                sourceShapeID: stableSourceID,
                occurrenceID: occurrenceID,
                layer: shape.layer,
                geometry: transformed(shape.geometry, by: transforms)
            ))
        }
        let orderedVias = cell.vias.enumerated().sorted {
            let lhsKey = viaOrderKey($0.element)
            let rhsKey = viaOrderKey($1.element)
            return lhsKey == rhsKey ? $0.offset < $1.offset : lhsKey < rhsKey
        }
        for (viaIndex, indexedVia) in orderedVias.enumerated() {
            let via = indexedVia.element
            let stableSourceID = "via:/\(path.joined(separator: "/"))/#\(viaIndex)"
            output.vias.append(FlatVia(
                objectID: LayoutExtractionObjectID(
                    rawValue: stableSourceID
                ),
                sourceViaID: stableSourceID,
                occurrenceID: occurrenceID,
                definitionID: via.viaDefinitionID,
                point: transformed(via.position, by: transforms)
            ))
        }
        for label in cell.labels.sorted(by: labelOrder) {
            output.labels.append(FlatLabel(
                name: label.text,
                point: transformed(label.position, by: transforms),
                layer: label.layer,
                topLevel: topLevel
            ))
        }
        for pin in cell.pins.sorted(by: pinOrder) {
            output.pins.append(FlatPin(
                name: pin.name,
                point: transformed(pin.position, by: transforms),
                layer: pin.layer,
                topLevel: topLevel
            ))
        }
        guard output.shapes.count + output.occurrences.count <= maximumObjectCount else {
            throw LayoutGeometryExtractionError.objectBudgetExceeded(limit: maximumObjectCount)
        }
        let orderedInstances = cell.instances.enumerated().sorted {
            let lhsKey = instanceOrderKey($0.element, document: document)
            let rhsKey = instanceOrderKey($1.element, document: document)
            return lhsKey == rhsKey ? $0.offset < $1.offset : lhsKey < rhsKey
        }
        for (instanceIndex, indexedInstance) in orderedInstances.enumerated() {
            let instance = indexedInstance.element
            guard let child = document.cell(withID: instance.cellID) else {
                throw LayoutGeometryExtractionError.missingReferencedCell(instance.cellID.uuidString)
            }
            for (index, occurrenceTransform) in instance.occurrenceTransforms().enumerated() {
                try flatten(
                    cell: child,
                    document: document,
                    path: path + ["\(instance.name)#\(instanceIndex)[\(index)]", child.name],
                    transforms: [occurrenceTransform] + transforms,
                    activeCellIDs: nextActiveCellIDs,
                    topLevel: false,
                    maximumObjectCount: maximumObjectCount,
                    output: &output
                )
            }
        }
    }

    private func instanceOrderKey(_ instance: LayoutInstance, document: LayoutDocument) -> String {
        return [
            instance.name,
            document.cell(withID: instance.cellID)?.name ?? "<missing>",
            instance.occurrenceTransforms().map { transformDescription([$0]) }.joined(separator: ";"),
        ].joined(separator: "|")
    }

    private func shapeOrderKey(_ shape: LayoutShape) -> String {
        [shape.layer.name, shape.layer.purpose, geometryOrderKey(shape.geometry)].joined(separator: "|")
    }

    private func geometryOrderKey(_ geometry: LayoutGeometry) -> String {
        switch geometry {
        case .rect(let rect):
            return "rect|\(pointOrderKey(rect.origin))|\(rect.size.width)|\(rect.size.height)"
        case .polygon(let polygon):
            return "polygon|\(polygon.points.map(pointOrderKey).joined(separator: ";"))"
        case .path(let path):
            return "path|\(path.points.map(pointOrderKey).joined(separator: ";"))|\(path.width)|\(path.endCap.rawValue)"
        }
    }

    private func viaOrderKey(_ via: LayoutVia) -> String {
        "\(via.viaDefinitionID)|\(pointOrderKey(via.position))"
    }

    private func labelOrder(_ lhs: LayoutLabel, _ rhs: LayoutLabel) -> Bool {
        labelOrderKey(lhs) < labelOrderKey(rhs)
    }

    private func labelOrderKey(_ label: LayoutLabel) -> String {
        [label.text, label.layer.name, label.layer.purpose, pointOrderKey(label.position)]
            .joined(separator: "|")
    }

    private func pinOrder(_ lhs: LayoutPin, _ rhs: LayoutPin) -> Bool {
        pinOrderKey(lhs) < pinOrderKey(rhs)
    }

    private func pinOrderKey(_ pin: LayoutPin) -> String {
        [pin.name, pin.layer.name, pin.layer.purpose, pointOrderKey(pin.position)]
            .joined(separator: "|")
    }

    private func pointOrderKey(_ point: LayoutPoint) -> String {
        "\(point.x),\(point.y)"
    }

    private struct RectShape: Sendable {
        let objectID: LayoutExtractionObjectID
        let sourceShapeID: String
        let occurrenceID: LayoutExtractionObjectID
        let layer: LayoutLayerID
        let rect: LayoutRect
    }

    private struct Channel: Sendable {
        let id: LayoutExtractionObjectID
        let diffusion: RectShape
        let gate: RectShape
        let rect: LayoutRect
        let terminalCenter: LayoutPoint
        let fragments: [ChannelFragment]
        let horizontalCurrent: Bool
        let rule: LayoutExtractionMOSRule
    }

    private struct ChannelFragment: Sendable {
        let diffusionObjectID: LayoutExtractionObjectID
        let rect: LayoutRect
        let horizontalCurrent: Bool
    }

    private struct ConductorPiece: Sendable {
        let id: LayoutExtractionObjectID
        let sourceShapeID: String
        let occurrenceID: LayoutExtractionObjectID
        let layer: LayoutLayerID
        let rect: LayoutRect
    }

    private func buildIR(
        from flattened: FlattenedLayout,
        technology: LayoutTechDatabase,
        profile: LayoutExtractionProcessProfile,
        maximumObjectCount: Int
    ) -> LayoutExtractionIR {
        var issues: [LayoutExtractionIssue] = []
        let shapeRectangles = flattened.shapes.flatMap { shape -> [RectShape] in
            let rects = rectangles(for: shape.geometry)
            if rects.isEmpty {
                issues.append(LayoutExtractionIssue(
                    code: "unsupported-geometry",
                    severity: .blocking,
                    message: "Extraction requires rectilinear polygon, rectangle, or axis-aligned path geometry.",
                    affectedObjectIDs: [shape.objectID]
                ))
            }
            return rects.enumerated().map { index, rect in
                RectShape(
                    objectID: LayoutExtractionObjectID(rawValue: "\(shape.objectID.rawValue):rect:\(index)"),
                    sourceShapeID: shape.sourceShapeID,
                    occurrenceID: shape.occurrenceID,
                    layer: shape.layer,
                    rect: rect
                )
            }
        }
        let viaRectangles = flattened.vias.compactMap { via -> RectShape? in
            guard let definition = technology.viaDefinition(for: via.definitionID) else {
                issues.append(LayoutExtractionIssue(
                    code: "via-definition-missing",
                    severity: .blocking,
                    message: "Via '\(via.definitionID)' has no technology definition.",
                    affectedObjectIDs: [via.objectID]
                ))
                return nil
            }
            return RectShape(
                objectID: via.objectID,
                sourceShapeID: via.sourceViaID,
                occurrenceID: via.occurrenceID,
                layer: definition.cutLayer,
                rect: LayoutRect(
                    origin: LayoutPoint(
                        x: via.point.x - definition.cutSize.width / 2,
                        y: via.point.y - definition.cutSize.height / 2
                    ),
                    size: definition.cutSize
                )
            )
        }
        let rectShapes = shapeRectangles + viaRectangles
        var channels: [Channel] = []
        for diffusion in rectShapes where profile.mosRules.contains(where: { $0.diffusionLayers.matches(diffusion.layer) }) {
            for gate in rectShapes where profile.mosRules.contains(where: { $0.gateLayers.matches(gate.layer) }) {
                guard let intersection = positiveIntersection(diffusion.rect, gate.rect) else { continue }
                let crossesHeight = intersection.minY <= diffusion.rect.minY + epsilon
                    && intersection.maxY >= diffusion.rect.maxY - epsilon
                let crossesWidth = intersection.minX <= diffusion.rect.minX + epsilon
                    && intersection.maxX >= diffusion.rect.maxX - epsilon
                guard crossesHeight != crossesWidth else { continue }
                let matchingRules = profile.mosRules.filter { rule in
                    rule.diffusionLayers.matches(diffusion.layer)
                        && rule.gateLayers.matches(gate.layer)
                        && rectShapes.contains {
                            rule.selectorLayers.matches($0.layer) && contains(intersection.center, in: $0.rect)
                        }
                        && !rectShapes.contains {
                            rule.exclusionLayers.matches($0.layer) && contains(intersection.center, in: $0.rect)
                        }
                }
                guard matchingRules.count == 1, let rule = matchingRules.first else {
                    issues.append(LayoutExtractionIssue(
                        code: matchingRules.isEmpty ? "device-selector-missing" : "device-selector-ambiguous",
                        severity: .blocking,
                        message: "A channel must resolve to exactly one process device rule.",
                        affectedObjectIDs: [diffusion.objectID, gate.objectID]
                    ))
                    continue
                }
                channels.append(Channel(
                    id: LayoutExtractionObjectID(rawValue: "channel:\(diffusion.objectID.rawValue):\(gate.objectID.rawValue)"),
                    diffusion: diffusion,
                    gate: gate,
                    rect: intersection,
                    terminalCenter: intersection.center,
                    fragments: [ChannelFragment(
                        diffusionObjectID: diffusion.objectID,
                        rect: intersection,
                        horizontalCurrent: crossesHeight
                    )],
                    horizontalCurrent: crossesHeight,
                    rule: rule
                ))
            }
        }
        channels = consolidatedChannels(channels)
        var pieces: [ConductorPiece] = []
        for shape in rectShapes where profile.conductorLayers.matches(shape.layer) {
            if profile.mosRules.contains(where: { $0.diffusionLayers.matches(shape.layer) }) {
                let channelCuts = channels.flatMap(\.fragments).filter {
                    $0.diffusionObjectID == shape.objectID
                }
                let fragments = diffusionFragments(shape.rect, cuts: channelCuts)
                pieces.append(contentsOf: fragments.enumerated().map { index, rect in
                    ConductorPiece(
                        id: LayoutExtractionObjectID(rawValue: "conductor:\(shape.objectID.rawValue):\(index)"),
                        sourceShapeID: shape.sourceShapeID,
                        occurrenceID: shape.occurrenceID,
                        layer: shape.layer,
                        rect: rect
                    )
                })
            } else {
                pieces.append(ConductorPiece(
                    id: LayoutExtractionObjectID(rawValue: "conductor:\(shape.objectID.rawValue)"),
                    sourceShapeID: shape.sourceShapeID,
                    occurrenceID: shape.occurrenceID,
                    layer: shape.layer,
                    rect: shape.rect
                ))
            }
        }
        if pieces.count + channels.count > maximumObjectCount {
            issues.append(LayoutExtractionIssue(
                code: "extraction-object-budget-exceeded",
                severity: .blocking,
                message: "Extraction exceeded the configured object budget."
            ))
        }
        var union = IntegerUnionFind(count: pieces.count)
        for first in pieces.indices {
            for second in pieces.indices where second > first
                && pieces[first].layer == pieces[second].layer
                && touches(pieces[first].rect, pieces[second].rect) {
                union.join(first, second)
            }
        }
        let technologyConnectionRules = technology.vias.map { via in
            LayoutExtractionConnectionRule(
                cutLayers: LayoutExtractionLayerReference(names: [via.cutLayer.name]),
                lowerLayers: LayoutExtractionLayerReference(names: [via.bottomLayer.name]),
                upperLayers: LayoutExtractionLayerReference(names: [via.topLayer.name])
            )
        } + technology.contacts.map { contact in
            LayoutExtractionConnectionRule(
                cutLayers: LayoutExtractionLayerReference(names: [contact.cutLayer.name]),
                lowerLayers: LayoutExtractionLayerReference(names: [contact.bottomLayer.name]),
                upperLayers: LayoutExtractionLayerReference(names: [contact.topLayer.name])
            )
        }
        let connectionRules = profile.connectionRules + technologyConnectionRules
        for cut in rectShapes {
            let matchingRules = connectionRules.filter { $0.cutLayers.matches(cut.layer) }
            guard !matchingRules.isEmpty else { continue }
            var connected = false
            for rule in matchingRules {
                let lower = pieces.indices.filter {
                    rule.lowerLayers.matches(pieces[$0].layer) && touches(cut.rect, pieces[$0].rect)
                }
                let upper = pieces.indices.filter {
                    rule.upperLayers.matches(pieces[$0].layer) && touches(cut.rect, pieces[$0].rect)
                }
                guard !lower.isEmpty, !upper.isEmpty else { continue }
                connected = true
                for lowerIndex in lower {
                    for upperIndex in upper { union.join(lowerIndex, upperIndex) }
                }
            }
            if !connected {
                issues.append(LayoutExtractionIssue(
                    code: "contact-open",
                    severity: .blocking,
                    message: "A contact cut does not connect both conductor sides.",
                    affectedObjectIDs: [cut.objectID]
                ))
            }
        }
        var namesByRoot: [Int: Set<String>] = [:]
        for label in flattened.labels {
            let matches = pieces.indices.filter {
                pieces[$0].layer == label.layer && contains(label.point, in: pieces[$0].rect)
            }
            for index in matches { namesByRoot[union.root(index), default: []].insert(label.name) }
        }
        for pin in flattened.pins {
            let matches = pieces.indices.filter {
                pieces[$0].layer == pin.layer && contains(pin.point, in: pieces[$0].rect)
            }
            for index in matches { namesByRoot[union.root(index), default: []].insert(pin.name) }
        }
        for (root, names) in namesByRoot where names.count > 1 {
            issues.append(LayoutExtractionIssue(
                code: "net-label-ambiguity",
                severity: .blocking,
                message: "Connected geometry has conflicting names: \(names.sorted().joined(separator: ", ")).",
                affectedObjectIDs: [pieces[root].id]
            ))
        }
        let roots = Set(pieces.indices.map { union.root($0) }).sorted()
        var netIDByRoot: [Int: LayoutExtractionObjectID] = [:]
        for root in roots {
            let memberIDs = pieces.indices.filter { union.root($0) == root }.map { pieces[$0].id.rawValue }.sorted()
            netIDByRoot[root] = LayoutExtractionObjectID(rawValue: "net:\(memberIDs.first ?? String(root))")
        }
        let portCandidates = flattened.labels.filter {
            $0.topLevel && profile.conductorLayers.matches($0.layer)
        }
            .map { ($0.name, $0.point, $0.layer) }
            + flattened.pins.filter(\.topLevel).map { ($0.name, $0.point, $0.layer) }
        var ports: [LayoutExtractionPort] = []
        var portNetByUpperName: [String: LayoutExtractionObjectID] = [:]
        for candidate in portCandidates.sorted(by: { $0.0 < $1.0 }) {
            guard let pieceIndex = pieces.indices.first(where: {
                pieces[$0].layer == candidate.2 && contains(candidate.1, in: pieces[$0].rect)
            }), let netID = netIDByRoot[union.root(pieceIndex)] else {
                issues.append(LayoutExtractionIssue(
                    code: "port-not-connected",
                    severity: .blocking,
                    message: "Top port '\(candidate.0)' is not on extracted conductor geometry."
                ))
                continue
            }
            guard portNetByUpperName[candidate.0.uppercased()] == nil else { continue }
            portNetByUpperName[candidate.0.uppercased()] = netID
            ports.append(LayoutExtractionPort(
                name: candidate.0,
                position: ports.count,
                netID: netID,
                occurrenceIDs: occurrenceIDs(for: union.root(pieceIndex), pieces: pieces, union: &union)
            ))
        }
        var extraNets: [LayoutExtractionNet] = []
        let devices = channels.enumerated().compactMap { index, channel -> LayoutExtractionDevice? in
            guard let gateIndex = conductorIndex(
                at: channel.rect.center,
                layer: channel.gate.layer,
                pieces: pieces
            ), let gateNet = netIDByRoot[union.root(gateIndex)] else {
                issues.append(blockingTerminalIssue("gate", channel: channel))
                return nil
            }
            let terminalPoints = sourceDrainPoints(channel)
            guard let firstIndex = conductorIndex(
                at: terminalPoints.0,
                layer: channel.diffusion.layer,
                pieces: pieces
            ), let secondIndex = conductorIndex(
                at: terminalPoints.1,
                layer: channel.diffusion.layer,
                pieces: pieces
            ), let firstNet = netIDByRoot[union.root(firstIndex)],
                  let secondNet = netIDByRoot[union.root(secondIndex)] else {
                issues.append(blockingTerminalIssue("source/drain", channel: channel))
                return nil
            }
            let geometricBulkPiece = pieces.indices
                .filter { channel.rule.bulkTapLayers.matches(pieces[$0].layer) }
                .filter { pieceIndex in
                    rectShapes.contains { selector in
                        channel.rule.bulkTapSelectorLayers.matches(selector.layer)
                            && positiveIntersection(selector.rect, pieces[pieceIndex].rect) != nil
                    }
                }
                .min { first, second in
                    squaredDistance(pieces[first].rect.center, channel.rect.center)
                        < squaredDistance(pieces[second].rect.center, channel.rect.center)
                }
            let geometricBulkNet = geometricBulkPiece.flatMap {
                netIDByRoot[union.root($0)]
            }
            let namedBulkNet = channel.rule.bulkPortCandidates.lazy.compactMap {
                portNetByUpperName[$0.uppercased()]
            }.first
            let bulkNet = channel.rule.preferNamedBulkPort
                ? namedBulkNet ?? geometricBulkNet
                : geometricBulkNet ?? namedBulkNet
            let resolvedBulkNet: LayoutExtractionObjectID
            if let bulkNet {
                resolvedBulkNet = bulkNet
            } else {
                resolvedBulkNet = LayoutExtractionObjectID(rawValue: "net:unresolved-bulk:\(index)")
                extraNets.append(LayoutExtractionNet(
                    id: resolvedBulkNet,
                    preferredName: nil,
                    occurrenceIDs: [channel.diffusion.occurrenceID]
                ))
                issues.append(blockingTerminalIssue("bulk", channel: channel))
            }
            let length = channel.horizontalCurrent ? channel.rect.size.width : channel.rect.size.height
            let width = channel.horizontalCurrent ? channel.rect.size.height : channel.rect.size.width
            return LayoutExtractionDevice(
                id: LayoutExtractionObjectID(rawValue: "device:\(channel.id.rawValue)"),
                model: channel.rule.model,
                family: "mosfet",
                terminals: [
                    LayoutExtractionTerminal(index: 0, role: "drain", netID: firstNet),
                    LayoutExtractionTerminal(index: 1, role: "gate", netID: gateNet),
                    LayoutExtractionTerminal(index: 2, role: "source", netID: secondNet),
                    LayoutExtractionTerminal(index: 3, role: "bulk", netID: resolvedBulkNet),
                ],
                parameters: ["l": "\(formatMicrons(length))u", "w": "\(formatMicrons(width))u"],
                typedParameters: [
                    LayoutExtractionTypedParameter(
                        name: "l",
                        kind: .number,
                        canonicalValue: formatMicrons(length),
                        numericValue: length,
                        unit: "um"
                    ),
                    LayoutExtractionTypedParameter(
                        name: "w",
                        kind: .number,
                        canonicalValue: formatMicrons(width),
                        numericValue: width,
                        unit: "um"
                    ),
                ],
                geometryReferences: [
                    geometryReference(channel.diffusion),
                    geometryReference(channel.gate),
                ],
                occurrenceIDs: [channel.diffusion.occurrenceID],
                deckRuleID: channel.rule.ruleID
            )
        }
        let allNets = roots.compactMap { root -> LayoutExtractionNet? in
            guard let netID = netIDByRoot[root] else { return nil }
            let memberPieces = pieces.indices.filter { union.root($0) == root }.map { pieces[$0] }
            return LayoutExtractionNet(
                id: netID,
                preferredName: namesByRoot[root]?.sorted().first,
                occurrenceIDs: occurrenceIDs(for: root, pieces: pieces, union: &union),
                isGlobal: isGlobalName(namesByRoot[root]?.first),
                geometryReferences: memberPieces.map(geometryReference)
            )
        } + extraNets
        let usedNetIDs = Set(
            devices.flatMap { $0.terminals.map(\.netID) }
                + ports.map(\.netID)
        )
        let nets = allNets.filter { usedNetIDs.contains($0.id) }
        return LayoutExtractionIR(
            processID: profile.processID,
            processProfileID: profile.processProfileID,
            extractionDeckDigest: profile.extractionDeckDigest,
            deckUseScope: profile.deckUseScope,
            parameterValueConvention: profile.parameterValueConvention,
            topCell: flattened.topCellName,
            devices: devices,
            nets: nets,
            ports: ports,
            occurrences: flattened.occurrences,
            transformLedger: flattened.occurrences.map { occurrence in
                let payload = "\(occurrence.objectID.rawValue)|\(occurrence.transformDescription)"
                return LayoutExtractionTransformRecord(
                    transformID: "flatten:\(occurrence.objectID.rawValue)",
                    kind: "hierarchy-flatten",
                    inputObjectIDs: [occurrence.objectID],
                    outputObjectIDs: [occurrence.objectID],
                    digest: SHA256.hash(data: Data(payload.utf8))
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            },
            issues: issues
        )
    }

    private func rectangles(for geometry: LayoutGeometry) -> [LayoutRect] {
        switch geometry {
        case .rect(let rect):
            return rect.size.width > epsilon && rect.size.height > epsilon ? [rect] : []
        case .path(let path):
            guard path.points.count == 2 else { return [] }
            let first = path.points[0]
            let second = path.points[1]
            guard abs(first.x - second.x) <= epsilon || abs(first.y - second.y) <= epsilon else { return [] }
            let halfWidth = path.width / 2
            return [LayoutRect(
                origin: LayoutPoint(x: min(first.x, second.x) - halfWidth, y: min(first.y, second.y) - halfWidth),
                size: LayoutSize(
                    width: abs(first.x - second.x) + path.width,
                    height: abs(first.y - second.y) + path.width
                )
            )]
        case .polygon(let polygon):
            let points = polygon.points.first == polygon.points.last
                ? Array(polygon.points.dropLast())
                : polygon.points
            guard points.count >= 4 else { return [] }
            for index in points.indices {
                let next = points[(index + 1) % points.count]
                guard abs(points[index].x - next.x) <= epsilon
                    || abs(points[index].y - next.y) <= epsilon else { return [] }
            }
            let xs = Array(Set(points.map(\.x))).sorted()
            var result: [LayoutRect] = []
            for pair in zip(xs, xs.dropFirst()) where pair.1 - pair.0 > epsilon {
                let x = (pair.0 + pair.1) / 2
                var intersections: [Double] = []
                for index in points.indices {
                    let first = points[index]
                    let second = points[(index + 1) % points.count]
                    guard abs(first.y - second.y) <= epsilon,
                          x > min(first.x, second.x) - epsilon,
                          x < max(first.x, second.x) + epsilon else { continue }
                    intersections.append(first.y)
                }
                intersections.sort()
                guard intersections.count.isMultiple(of: 2) else { return [] }
                for index in stride(from: 0, to: intersections.count, by: 2) {
                    let low = intersections[index]
                    let high = intersections[index + 1]
                    if high - low > epsilon {
                        result.append(LayoutRect(
                            origin: LayoutPoint(x: pair.0, y: low),
                            size: LayoutSize(width: pair.1 - pair.0, height: high - low)
                        ))
                    }
                }
            }
            return result
        }
    }

    private func diffusionFragments(_ rect: LayoutRect, cuts: [ChannelFragment]) -> [LayoutRect] {
        guard let first = cuts.first else { return [rect] }
        guard cuts.allSatisfy({ $0.horizontalCurrent == first.horizontalCurrent }) else { return [] }
        let horizontalCurrent = first.horizontalCurrent
        let cuts = cuts.sorted {
            horizontalCurrent ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }
        var result: [LayoutRect] = []
        var cursor = horizontalCurrent ? rect.minX : rect.minY
        for fragment in cuts {
            let cut = fragment.rect
            let start = horizontalCurrent ? cut.minX : cut.minY
            let end = horizontalCurrent ? cut.maxX : cut.maxY
            if start - cursor > epsilon {
                result.append(horizontalCurrent
                    ? LayoutRect(origin: LayoutPoint(x: cursor, y: rect.minY), size: LayoutSize(width: start - cursor, height: rect.size.height))
                    : LayoutRect(origin: LayoutPoint(x: rect.minX, y: cursor), size: LayoutSize(width: rect.size.width, height: start - cursor)))
            }
            cursor = max(cursor, end)
        }
        let end = horizontalCurrent ? rect.maxX : rect.maxY
        if end - cursor > epsilon {
            result.append(horizontalCurrent
                ? LayoutRect(origin: LayoutPoint(x: cursor, y: rect.minY), size: LayoutSize(width: end - cursor, height: rect.size.height))
                : LayoutRect(origin: LayoutPoint(x: rect.minX, y: cursor), size: LayoutSize(width: rect.size.width, height: end - cursor)))
        }
        return result
    }

    private func consolidatedChannels(_ channels: [Channel]) -> [Channel] {
        let groups = Dictionary(grouping: channels) {
            "\($0.gate.objectID.rawValue)|\($0.rule.ruleID)|\($0.horizontalCurrent)"
        }
        var result: [Channel] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            var remaining = Set(group.indices)
            while let seed = remaining.min() {
                var component = [seed]
                remaining.remove(seed)
                var cursor = 0
                while cursor < component.count {
                    let current = component[cursor]
                    let connected = remaining.filter {
                        touches(group[current].diffusion.rect, group[$0].diffusion.rect)
                    }
                    component.append(contentsOf: connected.sorted())
                    remaining.subtract(connected)
                    cursor += 1
                }
                let members = component.map { group[$0] }
                let canonical = members.sorted {
                    let lhsArea = channelArea($0.rect)
                    let rhsArea = channelArea($1.rect)
                    return lhsArea == rhsArea ? $0.id < $1.id : lhsArea > rhsArea
                }.first ?? group[seed]
                let mergedRect = boundingRect(members.map(\.rect))
                let memberIDs = members.map(\.id.rawValue).sorted().joined(separator: "+")
                result.append(Channel(
                    id: LayoutExtractionObjectID(rawValue: "channel-group:\(memberIDs)"),
                    diffusion: canonical.diffusion,
                    gate: canonical.gate,
                    rect: mergedRect,
                    terminalCenter: canonical.terminalCenter,
                    fragments: members.flatMap(\.fragments).sorted {
                        if $0.diffusionObjectID == $1.diffusionObjectID {
                            return geometryOrderKey(.rect($0.rect)) < geometryOrderKey(.rect($1.rect))
                        }
                        return $0.diffusionObjectID < $1.diffusionObjectID
                    },
                    horizontalCurrent: canonical.horizontalCurrent,
                    rule: canonical.rule
                ))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    private func channelArea(_ rect: LayoutRect) -> Double {
        rect.size.width * rect.size.height
    }

    private func boundingRect(_ rects: [LayoutRect]) -> LayoutRect {
        let minX = rects.map(\.minX).min() ?? 0
        let minY = rects.map(\.minY).min() ?? 0
        let maxX = rects.map(\.maxX).max() ?? minX
        let maxY = rects.map(\.maxY).max() ?? minY
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func sourceDrainPoints(_ channel: Channel) -> (LayoutPoint, LayoutPoint) {
        let delta = max(epsilon * 10, 1e-6)
        if channel.horizontalCurrent {
            return (
                LayoutPoint(x: channel.rect.minX - delta, y: channel.terminalCenter.y),
                LayoutPoint(x: channel.rect.maxX + delta, y: channel.terminalCenter.y)
            )
        }
        return (
            LayoutPoint(x: channel.terminalCenter.x, y: channel.rect.minY - delta),
            LayoutPoint(x: channel.terminalCenter.x, y: channel.rect.maxY + delta)
        )
    }

    private func conductorIndex(
        at point: LayoutPoint,
        layer: LayoutLayerID,
        pieces: [ConductorPiece]
    ) -> Int? {
        pieces.indices.first { pieces[$0].layer == layer && contains(point, in: pieces[$0].rect) }
    }

    private func blockingTerminalIssue(_ terminal: String, channel: Channel) -> LayoutExtractionIssue {
        LayoutExtractionIssue(
            code: "device-terminal-unresolved",
            severity: .blocking,
            message: "The \(terminal) terminal could not be resolved for model '\(channel.rule.model)'.",
            affectedObjectIDs: [channel.id],
            sourceLocation: channel.rule.sourceLocation
        )
    }

    private func geometryReference(_ shape: RectShape) -> LayoutExtractionGeometryReference {
        LayoutExtractionGeometryReference(
            objectID: shape.objectID,
            occurrenceID: shape.occurrenceID,
            sourceObjectID: shape.sourceShapeID,
            layer: shape.layer,
            bounds: shape.rect
        )
    }

    private func geometryReference(_ piece: ConductorPiece) -> LayoutExtractionGeometryReference {
        LayoutExtractionGeometryReference(
            objectID: piece.id,
            occurrenceID: piece.occurrenceID,
            sourceObjectID: piece.sourceShapeID,
            layer: piece.layer,
            bounds: piece.rect
        )
    }

    private func occurrenceIDs(
        for root: Int,
        pieces: [ConductorPiece],
        union: inout IntegerUnionFind
    ) -> [LayoutExtractionObjectID] {
        Array(Set(pieces.indices.filter { union.root($0) == root }.map { pieces[$0].occurrenceID })).sorted()
    }

    private func isGlobalName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == "0"
    }

    private func formatMicrons(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(format: "%.12g", value)
    }

    private func transformed(_ geometry: LayoutGeometry, by transforms: [LayoutTransform]) -> LayoutGeometry {
        transforms.reduce(geometry) { $0.transformed(by: $1) }
    }

    private func transformed(_ point: LayoutPoint, by transforms: [LayoutTransform]) -> LayoutPoint {
        transforms.reduce(point) { $1.apply(to: $0) }
    }

    private func transformDescription(_ transforms: [LayoutTransform]) -> String {
        transforms.map {
            "x=\($0.translation.x),y=\($0.translation.y),r=\($0.rotationDegrees),m=\($0.magnification),mx=\($0.mirrorX),my=\($0.mirrorY)"
        }.joined(separator: ";")
    }

    private func positiveIntersection(_ first: LayoutRect, _ second: LayoutRect) -> LayoutRect? {
        let minX = max(first.minX, second.minX)
        let minY = max(first.minY, second.minY)
        let maxX = min(first.maxX, second.maxX)
        let maxY = min(first.maxY, second.maxY)
        guard maxX - minX > epsilon, maxY - minY > epsilon else { return nil }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func touches(_ first: LayoutRect, _ second: LayoutRect) -> Bool {
        first.maxX >= second.minX - epsilon
            && second.maxX >= first.minX - epsilon
            && first.maxY >= second.minY - epsilon
            && second.maxY >= first.minY - epsilon
    }

    private func contains(_ point: LayoutPoint, in rect: LayoutRect) -> Bool {
        point.x >= rect.minX - epsilon && point.x <= rect.maxX + epsilon
            && point.y >= rect.minY - epsilon && point.y <= rect.maxY + epsilon
    }

    private func squaredDistance(_ first: LayoutPoint, _ second: LayoutPoint) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return dx * dx + dy * dy
    }
}

private struct IntegerUnionFind: Sendable {
    private var parents: [Int]
    private var ranks: [Int]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func root(_ index: Int) -> Int {
        if parents[index] != index { parents[index] = root(parents[index]) }
        return parents[index]
    }

    mutating func join(_ first: Int, _ second: Int) {
        let firstRoot = root(first)
        let secondRoot = root(second)
        guard firstRoot != secondRoot else { return }
        if ranks[firstRoot] < ranks[secondRoot] {
            parents[firstRoot] = secondRoot
        } else if ranks[firstRoot] > ranks[secondRoot] {
            parents[secondRoot] = firstRoot
        } else {
            parents[secondRoot] = firstRoot
            ranks[firstRoot] += 1
        }
    }
}
