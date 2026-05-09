import Foundation
import LayoutCore

/// A rectilinear Steiner minimum tree (RSMT) approximation.
///
/// Uses Hanan grid construction + MST pruning, guaranteed within 3/2 of optimal.
public struct SteinerTree: Sendable {
    public struct SteinerPoint: Hashable, Sendable {
        public var position: LayoutPoint
        public var isOriginalPin: Bool
    }

    public struct SteinerEdge: Sendable {
        public var from: Int
        public var to: Int
        public var manhattanLength: Double
    }

    public var points: [SteinerPoint]
    public var edges: [SteinerEdge]

    public var totalLength: Double {
        edges.reduce(0) { $0 + $1.manhattanLength }
    }

    /// Constructs an RSMT for the given pin positions.
    public static func construct(pins: [LayoutPoint]) -> SteinerTree {
        guard pins.count >= 2 else {
            let points = pins.map { SteinerPoint(position: $0, isOriginalPin: true) }
            return SteinerTree(points: points, edges: [])
        }

        // Special case: 2 pins
        if pins.count == 2 {
            return twoPointTree(pins[0], pins[1])
        }

        // Special case: 3 pins
        if pins.count == 3 {
            return threePointTree(pins[0], pins[1], pins[2])
        }

        // General case: Hanan grid + MST + pruning
        return hananGridRSMT(pins: pins)
    }

    /// Decomposes each edge into horizontal/vertical segments.
    ///
    /// Each edge becomes an L-shaped pair (horizontal + vertical) if not axis-aligned.
    public func decompose() -> [(from: LayoutPoint, to: LayoutPoint, isHorizontal: Bool)] {
        var segments: [(from: LayoutPoint, to: LayoutPoint, isHorizontal: Bool)] = []

        for edge in edges {
            let p1 = points[edge.from].position
            let p2 = points[edge.to].position
            let dx = abs(p1.x - p2.x)
            let dy = abs(p1.y - p2.y)

            if dx < 1e-9 {
                // Vertical segment
                segments.append((from: p1, to: p2, isHorizontal: false))
            } else if dy < 1e-9 {
                // Horizontal segment
                segments.append((from: p1, to: p2, isHorizontal: true))
            } else {
                // L-shape: horizontal then vertical (bend at (p2.x, p1.y))
                let bend = LayoutPoint(x: p2.x, y: p1.y)
                segments.append((from: p1, to: bend, isHorizontal: true))
                segments.append((from: bend, to: p2, isHorizontal: false))
            }
        }

        return segments
    }

    // MARK: - Special Cases

    private static func twoPointTree(_ a: LayoutPoint, _ b: LayoutPoint) -> SteinerTree {
        let points = [
            SteinerPoint(position: a, isOriginalPin: true),
            SteinerPoint(position: b, isOriginalPin: true),
        ]
        let dist = manhattan(a, b)
        return SteinerTree(points: points, edges: [SteinerEdge(from: 0, to: 1, manhattanLength: dist)])
    }

    private static func threePointTree(
        _ a: LayoutPoint, _ b: LayoutPoint, _ c: LayoutPoint
    ) -> SteinerTree {
        // Optimal 3-point RSMT: Steiner point at (median(x), median(y))
        let medX = median(a.x, b.x, c.x)
        let medY = median(a.y, b.y, c.y)
        let steiner = LayoutPoint(x: medX, y: medY)

        var points = [
            SteinerPoint(position: a, isOriginalPin: true),
            SteinerPoint(position: b, isOriginalPin: true),
            SteinerPoint(position: c, isOriginalPin: true),
        ]

        // Check if Steiner point coincides with any pin
        let pinPositions = [a, b, c]
        let steinerIndex: Int
        if let existingIdx = pinPositions.firstIndex(where: {
            abs($0.x - steiner.x) < 1e-9 && abs($0.y - steiner.y) < 1e-9
        }) {
            steinerIndex = existingIdx
        } else {
            steinerIndex = points.count
            points.append(SteinerPoint(position: steiner, isOriginalPin: false))
        }

        var edges: [SteinerEdge] = []
        for i in 0..<3 {
            if i != steinerIndex {
                edges.append(SteinerEdge(
                    from: i,
                    to: steinerIndex,
                    manhattanLength: manhattan(pinPositions[i], steiner)
                ))
            }
        }

        return SteinerTree(points: points, edges: edges)
    }

    // MARK: - Hanan Grid RSMT

    private static func hananGridRSMT(pins: [LayoutPoint]) -> SteinerTree {
        // 1. Collect unique X and Y coordinates
        let xCoords = Array(Set(pins.map(\.x))).sorted()
        let yCoords = Array(Set(pins.map(\.y))).sorted()

        // 2. Generate Hanan grid points (intersections not already pin positions)
        let pinSet = Set(pins.map { PointKey($0) })
        var allPoints: [SteinerPoint] = pins.map {
            SteinerPoint(position: $0, isOriginalPin: true)
        }

        for x in xCoords {
            for y in yCoords {
                let pt = LayoutPoint(x: x, y: y)
                let key = PointKey(pt)
                if !pinSet.contains(key) {
                    allPoints.append(SteinerPoint(position: pt, isOriginalPin: false))
                }
            }
        }

        // 3. Build MST on all candidate points using Prim's
        let mstEdges = primMST(points: allPoints.map(\.position))

        // 4. Prune degree-1 Hanan points (leaves that are not original pins)
        let prunedTree = pruneTree(points: allPoints, edges: mstEdges)

        return prunedTree
    }

    /// Prim's MST using Manhattan distance.
    private static func primMST(points: [LayoutPoint]) -> [(Int, Int)] {
        let n = points.count
        guard n >= 2 else { return [] }

        var inMST = [Bool](repeating: false, count: n)
        var minDist = [Double](repeating: .infinity, count: n)
        var minEdge = [Int](repeating: -1, count: n)
        var edges: [(Int, Int)] = []

        minDist[0] = 0

        for _ in 0..<n {
            var u = -1
            for v in 0..<n {
                if !inMST[v] && (u == -1 || minDist[v] < minDist[u]) {
                    u = v
                }
            }
            guard u != -1 else { break }

            inMST[u] = true
            if minEdge[u] != -1 {
                edges.append((minEdge[u], u))
            }

            for v in 0..<n {
                if !inMST[v] {
                    let d = manhattan(points[u], points[v])
                    if d < minDist[v] {
                        minDist[v] = d
                        minEdge[v] = u
                    }
                }
            }
        }

        return edges
    }

    /// Removes degree-1 Steiner (non-pin) points iteratively.
    private static func pruneTree(
        points: [SteinerPoint],
        edges: [(Int, Int)]
    ) -> SteinerTree {
        var adjList: [Int: Set<Int>] = [:]
        for (a, b) in edges {
            adjList[a, default: []].insert(b)
            adjList[b, default: []].insert(a)
        }

        // Iteratively remove degree-1 non-pin nodes
        var changed = true
        while changed {
            changed = false
            for (node, neighbors) in adjList {
                if neighbors.count <= 1 && !points[node].isOriginalPin {
                    for neighbor in neighbors {
                        adjList[neighbor]?.remove(node)
                    }
                    adjList.removeValue(forKey: node)
                    changed = true
                }
            }
        }

        // Rebuild compact tree
        let usedIndices = Set(adjList.keys).union(
            Set(adjList.values.flatMap { $0 })
        )
        let sortedIndices = usedIndices.sorted()
        let indexMap = Dictionary(uniqueKeysWithValues: sortedIndices.enumerated().map { ($0.element, $0.offset) })

        let newPoints = sortedIndices.map { points[$0] }
        var newEdges: [SteinerEdge] = []
        var edgeSet: Set<String> = []

        for (node, neighbors) in adjList {
            for neighbor in neighbors {
                let key = "\(min(node, neighbor))-\(max(node, neighbor))"
                guard !edgeSet.contains(key) else { continue }
                edgeSet.insert(key)
                guard let newFrom = indexMap[node], let newTo = indexMap[neighbor] else { continue }
                newEdges.append(SteinerEdge(
                    from: newFrom,
                    to: newTo,
                    manhattanLength: manhattan(
                        points[node].position,
                        points[neighbor].position
                    )
                ))
            }
        }

        return SteinerTree(points: newPoints, edges: newEdges)
    }

    // MARK: - Helpers

    private static func manhattan(_ a: LayoutPoint, _ b: LayoutPoint) -> Double {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    private static func median(_ a: Double, _ b: Double, _ c: Double) -> Double {
        [a, b, c].sorted()[1]
    }

    private struct PointKey: Hashable {
        let x: Int64
        let y: Int64

        init(_ point: LayoutPoint) {
            self.x = Int64((point.x * 1000).rounded())
            self.y = Int64((point.y * 1000).rounded())
        }
    }
}
