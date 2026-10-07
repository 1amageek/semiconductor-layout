import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import MaskGeometry

extension LayoutDRCService {
    func checkAntenna(
        shapes: [LayoutShape],
        vias: [LayoutVia],
        pins: [LayoutPin],
        tech: LayoutTechDatabase
    ) throws -> [LayoutViolation] {
        guard !tech.antennaRules.isEmpty else { return [] }

        let stack: LayoutConductorStack
        do {
            stack = try LayoutConductorStack.derive(from: tech)
        } catch {
            return [LayoutViolation(
                kind: .antenna,
                ruleID: "antenna.config.conductorStack",
                message: "Antenna check could not run: \(error).",
                suggestedFix: "Fix the via/contact definitions so their bottom-to-top layer relations form a DAG."
            )]
        }

        var violations: [LayoutViolation] = []

        var stagedRules: [(rule: LayoutAntennaRule, rank: Int)] = []
        for rule in tech.antennaRules {
            guard let rank = stack.rank(of: rule.layerID) else {
                violations.append(LayoutViolation(
                    kind: .antenna,
                    ruleID: antennaRuleID(rule),
                    message: "Antenna rule on layer \(rule.layerID.name) cannot be evaluated: the layer is not part of the conductor stack.",
                    layer: rule.layerID,
                    suggestedFix: "Connect \(rule.layerID.name) into the stack with a via/contact definition or remove the rule."
                ))
                continue
            }
            stagedRules.append((rule, rank))
        }
        guard !stagedRules.isEmpty else { return violations }
        stagedRules.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return antennaRuleID($0.rule) < antennaRuleID($1.rule)
        }

        // Cut layers bridge the conductor layers of the definitions that
        // use them, becoming real once their top layer is deposited.
        struct CutBridge {
            var layers: Set<LayoutLayerID> = []
            var activationRank = Int.max
        }
        var bridgeByCutLayer: [LayoutLayerID: CutBridge] = [:]
        for def in tech.vias {
            guard let topRank = stack.rank(of: def.topLayer) else { continue }
            var bridge = bridgeByCutLayer[def.cutLayer] ?? CutBridge()
            bridge.layers.formUnion([def.bottomLayer, def.topLayer])
            bridge.activationRank = min(bridge.activationRank, topRank)
            bridgeByCutLayer[def.cutLayer] = bridge
        }
        for def in tech.contacts {
            guard let topRank = stack.rank(of: def.topLayer) else { continue }
            var bridge = bridgeByCutLayer[def.cutLayer] ?? CutBridge()
            bridge.layers.formUnion([def.bottomLayer, def.topLayer])
            bridge.activationRank = min(bridge.activationRank, topRank)
            bridgeByCutLayer[def.cutLayer] = bridge
        }

        let dbu = evaluationScale(for: tech)
        func capturedBox(_ region: Region, sourceID: UUID) throws -> LayoutRect {
            guard let bounds = region.boundingBox else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
            }
            // Outward-only display bounds keep closed-cell broad-phase contact conservative.
            let minX = (Double(bounds.minX) / dbu).nextDown
            let minY = (Double(bounds.minY) / dbu).nextDown
            let maxX = (Double(bounds.maxX) / dbu).nextUp
            let maxY = (Double(bounds.maxY) / dbu).nextUp
            let box = LayoutRect(origin: .init(x: minX, y: minY),
                size: .init(width: (maxX - minX).nextUp, height: (maxY - minY).nextUp))
            guard minX.isFinite, minY.isFinite, box.maxX.isFinite, box.maxY.isFinite,
                  box.maxX >= maxX, box.maxY >= maxY else {
                throw ExactDRCGeometryError.invalidGridGeometry(sourceID: sourceID)
            }
            return box
        }

        struct Node {
            var geometry: LayoutGeometry
            var box: LayoutRect
            var layer: LayoutLayerID?
            var bridgeLayers: Set<LayoutLayerID>
            var activationRank: Int
            var shapeIndex: Int?
            var viaIndex: Int?
            var pinIndex: Int?
            var viaContacts: [LayoutLayerID: [LayoutRect]] = [:]
            var region: Region? = nil
            var viaContactRegions: [LayoutLayerID: Region] = [:]
        }
        var nodes: [Node] = []

        for (index, shape) in shapes.enumerated() {
            let region = try exactGeometry?.shapeRegion(at: index, source: shape)
            let box = try region.map { try capturedBox($0, sourceID: shape.id) }
                ?? LayoutGeometryAnalysis.boundingBox(for: shape.geometry)
            if let rank = stack.rank(of: shape.layer) {
                nodes.append(Node(
                    geometry: shape.geometry, box: box, layer: shape.layer,
                    bridgeLayers: [], activationRank: rank,
                    shapeIndex: index, viaIndex: nil, pinIndex: nil, region: region
                ))
            } else if let bridge = bridgeByCutLayer[shape.layer] {
                nodes.append(Node(
                    geometry: shape.geometry, box: box, layer: nil,
                    bridgeLayers: bridge.layers, activationRank: bridge.activationRank,
                    shapeIndex: index, viaIndex: nil, pinIndex: nil, region: region
                ))
            }
            // Wells, implants and markers do not conduct; they stay out.
        }

        var unknownViaDefinitionIDs: Set<String> = []
        for (index, via) in vias.enumerated() {
            let resolved: (cutSize: LayoutSize, bottom: LayoutLayerID, top: LayoutLayerID)?
            if let def = tech.viaDefinition(for: via.viaDefinitionID) {
                resolved = (def.cutSize, def.bottomLayer, def.topLayer)
            } else if let contact = tech.contactDefinition(for: via.viaDefinitionID) {
                resolved = (contact.cutSize, contact.bottomLayer, contact.topLayer)
            } else {
                resolved = nil
            }
            guard let cut = resolved, let topRank = stack.rank(of: cut.top) else {
                unknownViaDefinitionIDs.insert(via.viaDefinitionID)
                continue
            }
            let contactRegions = try exactGeometry?.viaRegions(at: index, source: via)
            let region = contactRegions.map { Region(polygons: $0.values.flatMap(\.polygons)) }
            let bounds = try region.map { try capturedBox($0, sourceID: via.id) }
                ?? (union(rects: viaConductorRects(for: via, tech: tech)) ?? viaCutBoundingBox(for: via, tech: tech))
            nodes.append(Node(
                geometry: .rect(bounds), box: bounds, layer: nil,
                bridgeLayers: [cut.bottom, cut.top], activationRank: topRank,
                shapeIndex: nil, viaIndex: index, pinIndex: nil,
                viaContacts: exactGeometry == nil ? viaContactRectsByLayer(for: via, tech: tech) : [:],
                region: region, viaContactRegions: contactRegions ?? [:]
            ))
        }
        for definitionID in unknownViaDefinitionIDs.sorted() {
            violations.append(LayoutViolation(
                kind: .antenna,
                ruleID: "antenna.config.viaDefinition",
                message: "Antenna connectivity cannot include vias with unknown definition '\(definitionID)'.",
                suggestedFix: "Add the via/contact definition to the technology database."
            ))
        }

        for (index, pin) in pins.enumerated() {
            guard let rank = stack.rank(of: pin.layer) else {
                if pin.role == .gate {
                    violations.append(LayoutViolation(
                        kind: .antenna,
                        ruleID: "antenna.config.gatePinLayer",
                        message: "Gate pin '\(pin.name)' sits on layer \(pin.layer.name) outside the conductor stack; its antenna exposure cannot be evaluated.",
                        layer: pin.layer,
                        pinIDs: [pin.id],
                        suggestedFix: "Place the gate pin on a conductor-stack layer or connect its layer with a via/contact definition."
                    ))
                }
                continue
            }
            let rect = LayoutRect(
                origin: LayoutPoint(
                    x: pin.position.x - pin.size.width / 2,
                    y: pin.position.y - pin.size.height / 2
                ),
                size: pin.size
            )
            let region = try exactGeometry?.pinRegion(at: index, source: pin)
            let box = try region.map { try capturedBox($0, sourceID: pin.id) } ?? rect
            nodes.append(Node(
                geometry: .rect(rect), box: box, layer: pin.layer,
                bridgeLayers: [], activationRank: rank,
                shapeIndex: nil, viaIndex: nil, pinIndex: index, region: region
            ))
        }

        guard !nodes.isEmpty else { return violations }

        let boxes = nodes.map(\.box)
        let grid = ShapeGridIndex(
            boundingBoxes: boxes,
            cellSize: ShapeGridIndex.defaultCellSize(for: boxes)
        )
        var unionFind = LayoutUnionFind(count: nodes.count)
        var active = [Bool](repeating: false, count: nodes.count)
        let activationOrder = nodes.indices.sorted {
            if nodes[$0].activationRank != nodes[$1].activationRank {
                return nodes[$0].activationRank < nodes[$1].activationRank
            }
            return $0 < $1
        }
        var activationCursor = 0

        func connects(_ a: Int, _ b: Int) throws -> Bool {
            let nodeA = nodes[a]
            let nodeB = nodes[b]
            let aIsBridge = !nodeA.bridgeLayers.isEmpty
            let bIsBridge = !nodeB.bridgeLayers.isEmpty
            if aIsBridge && bIsBridge { return false }
            // Pins are abstract terminals; they attach through geometry but
            // never join each other directly.
            if nodeA.pinIndex != nil && nodeB.pinIndex != nil { return false }
            if aIsBridge || bIsBridge {
                let bridge = aIsBridge ? nodeA : nodeB
                let conductor = aIsBridge ? nodeB : nodeA
                guard let layer = conductor.layer, bridge.bridgeLayers.contains(layer) else {
                    return false
                }
                if bridge.viaIndex != nil {
                    if exactGeometry != nil {
                        guard let landing = bridge.viaContactRegions[layer], let region = conductor.region else {
                            throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
                        }
                        return try regionsTouch(landing, region)
                    }
                    return try (bridge.viaContacts[layer] ?? []).contains {
                        try geometriesTouch(.rect($0), conductor.geometry, dbu: dbu)
                    }
                }
            } else {
                guard nodeA.layer == nodeB.layer else { return false }
            }
            if exactGeometry != nil {
                guard let first = nodeA.region, let second = nodeB.region else {
                    throw ExactDRCGeometryError.invalidGridGeometry(sourceID: nil)
                }
                return try regionsTouch(first, second)
            }
            return try geometriesTouch(nodeA.geometry, nodeB.geometry, dbu: dbu)
        }

        func activate(upTo rank: Int) throws {
            while activationCursor < activationOrder.count,
                  nodes[activationOrder[activationCursor]].activationRank <= rank {
                let index = activationOrder[activationCursor]
                activationCursor += 1
                active[index] = true
                for candidate in grid.candidateIndices(near: nodes[index].box)
                where candidate != index && active[candidate] {
                    guard unionFind.find(index) != unionFind.find(candidate) else { continue }
                    if try connects(index, candidate) {
                        unionFind.union(index, candidate)
                    }
                }
            }
        }

        let rulesByRank = Dictionary(grouping: stagedRules, by: { $0.rank })

        for rank in rulesByRank.keys.sorted() {
            try activate(upTo: rank)

            var componentMembers: [Int: [Int]] = [:]
            for index in nodes.indices where active[index] {
                componentMembers[unionFind.find(index), default: []].append(index)
            }
            // Members were appended in ascending node order, so the first
            // member orders components deterministically.
            let components = componentMembers.values.sorted { $0[0] < $1[0] }

            for component in components {
                var gatePins: [LayoutPin] = []
                var hasDischarge = false
                var componentShapes: [LayoutShape] = []
                var componentViaIDs: [UUID] = []
                for index in component {
                    let node = nodes[index]
                    if let pinIndex = node.pinIndex {
                        switch pins[pinIndex].role {
                        case .gate:
                            gatePins.append(pins[pinIndex])
                        case .source, .drain, .bulk:
                            hasDischarge = true
                        case .signal, .power, .ground:
                            break
                        }
                    }
                    if let shapeIndex = node.shapeIndex, node.layer != nil {
                        componentShapes.append(shapes[shapeIndex])
                    }
                    if let viaIndex = node.viaIndex {
                        componentViaIDs.append(vias[viaIndex].id)
                    }
                }
                if hasDischarge { continue }
                let gateArea = gatePins.reduce(0.0) { $0 + ($1.size.width * $1.size.height) }
                if gateArea <= 0 { continue }

                let componentNetIDs = antennaComponentNetIDs(shapes: componentShapes, pins: gatePins)

                for staged in rulesByRank[rank] ?? [] {
                    let rule = staged.rule
                    let layerShapes = componentShapes.filter { $0.layer == rule.layerID }
                    let layerArea = try mergedArea(of: layerShapes, dbu: dbu)
                    if layerArea > 0 {
                        let ratio = layerArea / gateArea
                        if ratio > rule.maxRatio {
                            violations.append(LayoutViolation(
                                kind: .antenna,
                                ruleID: antennaRuleID(rule),
                                message: "Antenna violation at the \(rule.layerID.name) etch stage: ratio \(ratio) exceeds \(rule.maxRatio).",
                                layer: rule.layerID,
                                region: overallBoundingBox(shapes: layerShapes) ?? .zero,
                                measured: ratio,
                                required: rule.maxRatio,
                                unit: "ratio",
                                shapeIDs: layerShapes.map(\.id),
                                viaIDs: componentViaIDs,
                                pinIDs: gatePins.map(\.id),
                                netIDs: componentNetIDs,
                                suggestedFix: "Insert an upper-layer jumper near the gate, add an antenna diode or diffusion tie, or reduce the metal area collected before the gate."
                            ))
                        }
                    }

                    if let maxCumulative = rule.maxCumulativeRatio {
                        var seenLayers: Set<LayoutLayerID> = []
                        var cumulativeArea = 0.0
                        var cumulativeShapes: [LayoutShape] = []
                        for contributing in stagedRules where contributing.rank <= rank {
                            guard seenLayers.insert(contributing.rule.layerID).inserted else { continue }
                            let shapesOnLayer = componentShapes.filter { $0.layer == contributing.rule.layerID }
                            cumulativeArea += try mergedArea(of: shapesOnLayer, dbu: dbu)
                            cumulativeShapes.append(contentsOf: shapesOnLayer)
                        }
                        guard cumulativeArea > 0 else { continue }
                        let ratio = cumulativeArea / gateArea
                        if ratio > maxCumulative {
                            violations.append(LayoutViolation(
                                kind: .antenna,
                                ruleID: cumulativeAntennaRuleID(rule),
                                message: "Cumulative antenna violation at the \(rule.layerID.name) etch stage: ratio \(ratio) exceeds \(maxCumulative).",
                                layer: rule.layerID,
                                region: overallBoundingBox(shapes: cumulativeShapes) ?? .zero,
                                measured: ratio,
                                required: maxCumulative,
                                unit: "ratio",
                                shapeIDs: cumulativeShapes.map(\.id),
                                viaIDs: componentViaIDs,
                                pinIDs: gatePins.map(\.id),
                                netIDs: componentNetIDs,
                                suggestedFix: "Insert an upper-layer jumper near the gate, add an antenna diode or diffusion tie, or reduce the total metal area collected before the gate."
                            ))
                        }
                    }
                }
            }
        }

        return violations
    }

    private func antennaComponentNetIDs(shapes: [LayoutShape], pins: [LayoutPin]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for shape in shapes {
            guard let netID = shape.netID, seen.insert(netID).inserted else { continue }
            result.append(netID)
        }
        for pin in pins {
            guard let netID = pin.netID, seen.insert(netID).inserted else { continue }
            result.append(netID)
        }
        return result
    }

    private func mergedArea(of shapes: [LayoutShape], dbu: Double) throws -> Double {
        guard !shapes.isEmpty else { return 0 }
        let region = try mergedRegion(of: shapes, dbu: dbu)
        return abs(Double(region.area)) / (dbu * dbu)
    }
}
