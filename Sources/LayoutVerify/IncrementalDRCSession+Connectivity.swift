import Foundation
import LayoutCore
import LayoutTech

extension IncrementalDRCSession {
    func openContacts(forShapeKey key: FlatShapeKey, shape: LayoutShape) -> Set<OpenContactKey> {
        guard let netID = shape.netID else { return [] }
        var contacts: Set<OpenContactKey> = []
        let box = LayoutGeometryAnalysis.boundingBox(for: shape.geometry)

        if let grid = shapeGridByLayer[shape.layer] {
            for candidateKey in grid.candidateKeys(of: box) where candidateKey != key {
                guard let candidate = shapeByKey[candidateKey],
                      candidate.netID == netID,
                      LayoutGeometryAnalysis.intersects(shape.geometry, candidate.geometry) else {
                    continue
                }
                contacts.insert(.shape(candidateKey))
            }
        }

        for viaKey in viaKeysByNet[netID] ?? [] {
            guard let via = viaByKey[viaKey],
                  let definition = tech.viaDefinition(for: via.viaDefinitionID),
                  shape.layer == definition.topLayer || shape.layer == definition.bottomLayer else {
                continue
            }
            let contactRects = service.viaLayerRects(for: via, layer: shape.layer, tech: tech)
            guard contactRects.contains(where: {
                box.intersects($0) && LayoutGeometryAnalysis.intersects(shape.geometry, .rect($0))
            }) else {
                continue
            }
            contacts.insert(.via(viaKey))
        }

        return contacts
    }

    func openContacts(forViaKey _: FlatViaKey, via: LayoutVia) -> Set<OpenContactKey> {
        guard let netID = via.netID,
              let definition = tech.viaDefinition(for: via.viaDefinitionID) else {
            return []
        }
        var contacts: Set<OpenContactKey> = []
        var visitedLayers: Set<LayoutLayerID> = []

        for layer in [definition.topLayer, definition.bottomLayer] where visitedLayers.insert(layer).inserted {
            guard let grid = shapeGridByLayer[layer] else { continue }
            for contactRect in service.viaLayerRects(for: via, layer: layer, tech: tech) {
                for candidateKey in grid.candidateKeys(of: contactRect) {
                    guard let shape = shapeByKey[candidateKey],
                          shape.netID == netID,
                          LayoutGeometryAnalysis.intersects(.rect(contactRect), shape.geometry) else {
                        continue
                    }
                    contacts.insert(.shape(candidateKey))
                }
            }
        }
        return contacts
    }

    func checkOpen(netID: UUID) -> [LayoutViolation] {
        let shapeEntries = (shapeKeysByNet[netID] ?? [])
            .sorted { shapeOrder($0) < shapeOrder($1) }
            .compactMap { key -> (key: FlatShapeKey, shape: LayoutShape)? in
                guard let shape = shapeByKey[key] else {
                    return nil
                }
                return (key: key, shape: shape)
            }
        guard !shapeEntries.isEmpty else { return [] }

        let viaEntries = (viaKeysByNet[netID] ?? [])
            .sorted { viaOrder($0) < viaOrder($1) }
            .compactMap { key -> (key: FlatViaKey, via: LayoutVia)? in
                guard let via = viaByKey[key] else {
                    return nil
                }
                return (key: key, via: via)
            }

        let elementCount = shapeEntries.count + viaEntries.count
        guard elementCount >= 2 else { return [] }

        var shapeIndexByKey: [FlatShapeKey: Int] = [:]
        shapeIndexByKey.reserveCapacity(shapeEntries.count)
        for (index, entry) in shapeEntries.enumerated() {
            shapeIndexByKey[entry.key] = index
        }

        var unionFind = LayoutUnionFind(count: elementCount)
        let shapeBoxes = shapeEntries.map {
            LayoutGeometryAnalysis.boundingBox(for: $0.shape.geometry)
        }
        let viaConductorBoxes = viaEntries.map {
            service.union(rects: service.viaConductorRects(for: $0.via, tech: tech)) ?? .zero
        }

        for (index, entry) in shapeEntries.enumerated() {
            guard let grid = shapeGridByLayer[entry.shape.layer] else { continue }
            for candidateKey in grid.candidateKeys(of: shapeBoxes[index]) {
                guard let candidateIndex = shapeIndexByKey[candidateKey],
                      candidateIndex > index,
                      let candidate = shapeByKey[candidateKey],
                      LayoutGeometryAnalysis.intersects(entry.shape.geometry, candidate.geometry) else {
                    continue
                }
                unionFind.union(index, candidateIndex)
            }
        }

        let viaStartIndex = shapeEntries.count
        for (offset, entry) in viaEntries.enumerated() {
            guard let definition = tech.viaDefinition(for: entry.via.viaDefinitionID) else { continue }
            let viaIndex = viaStartIndex + offset
            var visitedLayers: Set<LayoutLayerID> = []
            for layer in [definition.topLayer, definition.bottomLayer] where visitedLayers.insert(layer).inserted {
                guard let grid = shapeGridByLayer[layer] else { continue }
                for contactRect in service.viaLayerRects(for: entry.via, layer: layer, tech: tech) {
                    for candidateKey in grid.candidateKeys(of: contactRect) {
                        guard let shapeIndex = shapeIndexByKey[candidateKey],
                              let shape = shapeByKey[candidateKey],
                              LayoutGeometryAnalysis.intersects(.rect(contactRect), shape.geometry) else {
                            continue
                        }
                        unionFind.union(viaIndex, shapeIndex)
                    }
                }
            }
        }

        guard unionFind.components().count > 1 else { return [] }

        let geometries = shapeEntries.map(\.shape.geometry)
            + viaConductorBoxes.map { .rect($0) }
        return [
            LayoutViolation(
                kind: .disconnectedOpen,
                ruleID: "connectivity.open.disconnectedNet",
                message: "Open detected in net \(netID)",
                region: service.overallBoundingBox(geometries: geometries) ?? .zero,
                shapeIDs: shapeEntries.map(\.shape.id),
                viaIDs: viaEntries.map(\.via.id),
                netIDs: [netID],
                suggestedFix: "Add metal or vias to connect all geometry belonging to this net."
            )
        ]
    }

    func recomputeShorts(editedShapeIDs: Set<UUID>) -> [LayoutViolation] {
        guard !editedShapeIDs.isEmpty else { return [] }
        struct PairKey: Hashable {
            let lowOrder: Int
            let highOrder: Int
            let lowKey: FlatShapeKey
            let highKey: FlatShapeKey
        }
        var seenPairs: Set<PairKey> = []
        var pairs: [PairKey] = []
        for shapeID in editedShapeIDs {
            let editedKey = FlatShapeKey.top(shapeID)
            guard let edited = shapeByKey[editedKey],
                  let grid = shapeGridByLayer[edited.layer] else { continue }
            let editedBox = LayoutGeometryAnalysis.boundingBox(for: edited.geometry)
            let editedOrder = shapeOrder(editedKey)
            for partnerKey in grid.candidateKeys(of: editedBox) where partnerKey != editedKey {
                guard let partner = shapeByKey[partnerKey] else { continue }
                let partnerBox = LayoutGeometryAnalysis.boundingBox(for: partner.geometry)
                guard partnerBox.intersects(editedBox) else { continue }
                let partnerOrder = shapeOrder(partnerKey)
                let pair = editedOrder < partnerOrder ? PairKey(
                    lowOrder: editedOrder,
                    highOrder: partnerOrder,
                    lowKey: editedKey,
                    highKey: partnerKey
                ) : PairKey(
                    lowOrder: partnerOrder,
                    highOrder: editedOrder,
                    lowKey: partnerKey,
                    highKey: editedKey
                )
                guard seenPairs.insert(pair).inserted else { continue }
                pairs.append(pair)
            }
        }
        pairs.sort {
            if $0.lowOrder != $1.lowOrder { return $0.lowOrder < $1.lowOrder }
            return $0.highOrder < $1.highOrder
        }
        var violations: [LayoutViolation] = []
        for pair in pairs {
            guard let first = shapeByKey[pair.lowKey],
                  let second = shapeByKey[pair.highKey],
                  let violation = service.sameLayerShortViolation(first: first, second: second) else {
                continue
            }
            violations.append(violation)
        }
        return violations
    }
}
