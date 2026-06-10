import Foundation
import LayoutCore

/// Fabrication order of the conductor layers, derived from the via and
/// contact definitions: a cut's bottom layer is always fabricated before
/// its top layer. Ranks are longest-path depths in that relation, so
/// layers deposited before the first metal (e.g. ACTIVE and POLY) share
/// rank 0 and each metal ranks strictly above everything it lands on.
///
/// The rank order drives staged analyses such as antenna checking: when
/// layer K is being etched, only conductors with rank ≤ rank(K) — and the
/// cuts whose top layer has rank ≤ rank(K) — physically exist.
public struct LayoutConductorStack: Hashable, Sendable {
    /// Longest-path rank per conductor layer; higher rank = fabricated later.
    public let rankByLayer: [LayoutLayerID: Int]

    public func rank(of layer: LayoutLayerID) -> Int? {
        rankByLayer[layer]
    }

    /// Highest rank present in the stack.
    public var topRank: Int {
        rankByLayer.values.max() ?? 0
    }

    /// Derives the stack from the bottom→top relations of `tech.vias` and
    /// `tech.contacts`. Throws when no relations exist or they are cyclic;
    /// callers must surface that as an explicit configuration failure.
    public static func derive(from tech: LayoutTechDatabase) throws -> LayoutConductorStack {
        var edges: [(below: LayoutLayerID, above: LayoutLayerID)] = []
        for via in tech.vias {
            edges.append((via.bottomLayer, via.topLayer))
        }
        for contact in tech.contacts {
            edges.append((contact.bottomLayer, contact.topLayer))
        }
        guard !edges.isEmpty else {
            throw LayoutConductorStackError.noCutDefinitions
        }
        if edges.contains(where: { $0.below == $0.above }) {
            throw LayoutConductorStackError.cyclicLayerOrder
        }

        var nodes: Set<LayoutLayerID> = []
        for edge in edges {
            nodes.insert(edge.below)
            nodes.insert(edge.above)
        }

        var inDegree: [LayoutLayerID: Int] = [:]
        var successors: [LayoutLayerID: [LayoutLayerID]] = [:]
        for node in nodes {
            inDegree[node] = 0
        }
        for edge in edges {
            successors[edge.below, default: []].append(edge.above)
            inDegree[edge.above, default: 0] += 1
        }

        // Kahn's algorithm with longest-path ranks.
        var rank: [LayoutLayerID: Int] = [:]
        var queue: [LayoutLayerID] = nodes.filter { inDegree[$0] == 0 }
        for node in queue {
            rank[node] = 0
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let currentRank = rank[current] ?? 0
            for next in successors[current] ?? [] {
                rank[next] = max(rank[next] ?? 0, currentRank + 1)
                inDegree[next]! -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        guard rank.count == nodes.count else {
            throw LayoutConductorStackError.cyclicLayerOrder
        }

        return LayoutConductorStack(rankByLayer: rank)
    }
}
