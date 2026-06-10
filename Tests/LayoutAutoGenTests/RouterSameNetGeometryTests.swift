import Foundation
import Testing
@testable import LayoutAutoGen
import LayoutCore
import LayoutTech

/// Contract: every same-net, same-layer feature a router emits either merges
/// with its neighbours (touching/overlapping) or keeps the full minimum
/// spacing. A positive gap below minimum spacing is a sliver that spacing
/// DRC rejects regardless of net.
@Suite("Router Same-Net Geometry Contract")
struct RouterSameNetGeometryTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
    private let m2 = LayoutLayerID(name: "M2", purpose: "drawing")

    @Test func routedShapesMergeOrKeepSpacing() throws {
        let tech = LayoutTechDatabase.standard()
        let netID = UUID()
        let pinPositions = [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 2, y: 3),
            LayoutPoint(x: 0.5, y: 2),
        ]
        let net = RoutingNet(
            id: netID,
            name: "sig",
            pins: pinPositions.map { position in
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "P",
                    absolutePosition: position,
                    layer: m1
                )
            },
            isPower: false
        )

        let result = try SimpleRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: tech
        )

        #expect(result.unroutedNets.isEmpty)
        let routed = try #require(result.routes.first)
        for layer in [m1, m2] {
            let rules = try #require(tech.ruleSet(for: layer))
            let rects: [LayoutRect] = routed.shapes
                .filter { $0.layer == layer }
                .compactMap { shape in
                    if case .rect(let rect) = shape.geometry { return rect }
                    return nil
                }
            // Merged features keep spacing: cluster touching rects first,
            // then every cross-cluster pair must hold the full spacing.
            let clusterIDs = clusterIndices(rects)
            for i in rects.indices {
                for j in rects.indices where j > i && clusterIDs[i] != clusterIDs[j] {
                    let gap = separation(rects[i], rects[j])
                    #expect(
                        gap >= rules.minSpacing - 1.0e-9,
                        "same-net \(layer.name) features at sliver gap \(gap)µm"
                    )
                }
            }
        }
    }

    @Test func stitchViasAreNotDuplicatedPerShapePair() throws {
        let tech = LayoutTechDatabase.standard()
        let netID = UUID()
        // A-B horizontal trunk plus C dropping onto it forces an M2 segment
        // crossing the M1 trunk: the old per-shape-pair stitching spawned a
        // via farm around the junction.
        let pinPositions = [
            LayoutPoint(x: 0, y: 0),
            LayoutPoint(x: 4, y: 0),
            LayoutPoint(x: 2, y: 3),
        ]
        let net = RoutingNet(
            id: netID,
            name: "sig",
            pins: pinPositions.map { position in
                RoutingPin(
                    instanceID: UUID(),
                    pinName: "P",
                    absolutePosition: position,
                    layer: m1
                )
            },
            isPower: false
        )

        let result = try SimpleRoutingEngine().route(
            nets: [net],
            placements: [:],
            cells: [:],
            obstructions: [],
            tech: tech
        )

        let routed = try #require(result.routes.first)
        var keys = Set<String>()
        for via in routed.vias {
            let key = "\(Int64((via.position.x * 1000).rounded()))_\(Int64((via.position.y * 1000).rounded()))"
            #expect(keys.insert(key).inserted, "duplicate via at \(via.position)")
        }
    }

    // MARK: - Helpers

    private func clusterIndices(_ rects: [LayoutRect]) -> [Int] {
        var parent = Array(rects.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for i in rects.indices {
            for j in rects.indices where j > i && separation(rects[i], rects[j]) <= 1.0e-9 {
                let ri = find(i)
                let rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        return rects.indices.map { find($0) }
    }

    private func separation(_ a: LayoutRect, _ b: LayoutRect) -> Double {
        let dx = max(0, max(b.origin.x - (a.origin.x + a.size.width), a.origin.x - (b.origin.x + b.size.width)))
        let dy = max(0, max(b.origin.y - (a.origin.y + a.size.height), a.origin.y - (b.origin.y + b.size.height)))
        return (dx * dx + dy * dy).squareRoot()
    }
}

@Suite("ObstructionMap Same-Net Sliver")
struct ObstructionMapSliverTests {
    private let m1 = LayoutLayerID(name: "M1", purpose: "drawing")

    private func map(registering rect: LayoutRect, netID: UUID?) -> ObstructionMap {
        var map = ObstructionMap()
        map.register(rect: rect, layer: m1, netID: netID)
        return map
    }

    private func unitSquare(x: Double, y: Double) -> LayoutRect {
        LayoutRect(origin: LayoutPoint(x: x, y: y), size: LayoutSize(width: 1, height: 1))
    }

    @Test func sliverGapBelowSpacingIsDetected() {
        let netID = UUID()
        let map = map(registering: unitSquare(x: 0, y: 0), netID: netID)
        #expect(map.hasSameNetSliver(
            rect: unitSquare(x: 1.03, y: 0),
            layer: m1,
            spacing: 0.05,
            netID: netID
        ))
    }

    @Test func touchingGeometryIsNotASliver() {
        let netID = UUID()
        let map = map(registering: unitSquare(x: 0, y: 0), netID: netID)
        #expect(!map.hasSameNetSliver(
            rect: unitSquare(x: 1.0, y: 0),
            layer: m1,
            spacing: 0.05,
            netID: netID
        ))
    }

    @Test func compliantSpacingIsNotASliver() {
        let netID = UUID()
        let map = map(registering: unitSquare(x: 0, y: 0), netID: netID)
        #expect(!map.hasSameNetSliver(
            rect: unitSquare(x: 1.05, y: 0),
            layer: m1,
            spacing: 0.05,
            netID: netID
        ))
    }

    @Test func otherNetGapIsNotASameNetSliver() {
        let map = map(registering: unitSquare(x: 0, y: 0), netID: UUID())
        #expect(!map.hasSameNetSliver(
            rect: unitSquare(x: 1.03, y: 0),
            layer: m1,
            spacing: 0.05,
            netID: UUID()
        ))
    }

    @Test func diagonalCornerGapUsesEuclideanMetric() {
        let netID = UUID()
        let map = map(registering: unitSquare(x: 0, y: 0), netID: netID)
        // Corner-to-corner gap is hypot(0.02, 0.02) ≈ 0.028 < 0.05.
        #expect(map.hasSameNetSliver(
            rect: unitSquare(x: 1.02, y: 1.02),
            layer: m1,
            spacing: 0.05,
            netID: netID
        ))
    }
}
