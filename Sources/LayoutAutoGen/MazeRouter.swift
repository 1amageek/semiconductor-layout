import Foundation
import LayoutCore
import LayoutTech

/// A* maze router operating on CongestionGrid coordinates.
///
/// Provides a fallback routing path when the ChannelRouter's L-shape options
/// are both obstructed. Searches a 3D space (row, col, layer) where:
/// - Layer 0 = M1 (preferred horizontal)
/// - Layer 1 = M2 (preferred vertical)
struct MazeRouter: Sendable {

    // MARK: - Cost Configuration

    struct CostConfig: Sendable {
        var bendPenalty: Double = 1.5
        var viaPenalty: Double = 2.0
        var wrongWayPenalty: Double = 3.0
        var historyFactor: Double = 0.5
        var presentPenalty: Double = 2.0
        var baseCellCost: Double = 1.0

        init() {}
    }

    let costConfig: CostConfig

    init(costConfig: CostConfig = CostConfig()) {
        self.costConfig = costConfig
    }

    // MARK: - 3D Node

    private struct Node3D: Hashable {
        let row: Int
        let col: Int
        let layer: Int  // 0 = M1, 1 = M2
    }

    private enum Direction: Int, CaseIterable {
        case north = 0  // row+1
        case south = 1  // row-1
        case east  = 2  // col+1
        case west  = 3  // col-1
    }

    // MARK: - Priority Queue Entry

    private struct PQEntry: Comparable {
        let node: Node3D
        let fCost: Double  // g + h
        let gCost: Double  // actual cost so far

        static func < (lhs: PQEntry, rhs: PQEntry) -> Bool {
            lhs.fCost < rhs.fCost
        }
    }

    // MARK: - Route

    /// Routes from a source to a destination in grid coordinates.
    ///
    /// - Parameters:
    ///   - from: Source layout point.
    ///   - to: Destination layout point.
    ///   - layers: Tuple of (m1ID, m2ID) layer identifiers.
    ///   - congestion: Congestion grid for cost evaluation.
    ///   - obstMap: Obstruction map for collision detection.
    ///   - tech: Technology database for metal widths and spacing.
    /// - Returns: Array of RouteSegments compatible with ChannelRouter output,
    ///            or nil if no path found.
    func route(
        from source: LayoutPoint,
        to destination: LayoutPoint,
        layers: (m1: LayoutLayerID, m2: LayoutLayerID),
        congestion: CongestionGrid,
        obstMap: ObstructionMap,
        tech: LayoutTechDatabase
    ) throws -> [ChannelRouter.RouteSegment]? {
        let m1Rules = try tech.requiredRuleSet(for: layers.m1)
        let m2Rules = try tech.requiredRuleSet(for: layers.m2)
        let m1Width = m1Rules.minWidth
        let m2Width = m2Rules.minWidth
        let m1Spacing = m1Rules.minSpacing
        let m2Spacing = m2Rules.minSpacing

        let srcCoord = congestion.gridCoordinates(for: source)
        let dstCoord = congestion.gridCoordinates(for: destination)

        // Start on M1 (layer 0), allow either layer at destination
        let startNode = Node3D(row: srcCoord.row, col: srcCoord.col, layer: 0)
        let goalRow = dstCoord.row
        let goalCol = dstCoord.col

        // A* search
        var openSet = MinHeap<PQEntry>()
        var gScores: [Node3D: Double] = [:]
        var cameFrom: [Node3D: Node3D] = [:]
        var directionFrom: [Node3D: Direction?] = [:]

        gScores[startNode] = 0
        directionFrom[startNode] = nil
        let startH = heuristic(srcCoord.row, srcCoord.col, goalRow, goalCol)
        openSet.insert(PQEntry(node: startNode, fCost: startH, gCost: 0))

        let maxExpansions = congestion.rows * congestion.cols * 2 * 4
        var expansions = 0

        while let current = openSet.extractMin() {
            expansions += 1
            if expansions > maxExpansions { return nil }

            let node = current.node

            // Goal reached on either layer
            if node.row == goalRow && node.col == goalCol {
                return reconstructPath(
                    cameFrom: cameFrom,
                    end: node,
                    congestion: congestion,
                    layers: layers,
                    m1Width: m1Width,
                    m2Width: m2Width
                )
            }

            // Skip if we already found a better path to this node
            if let known = gScores[node], current.gCost > known + 1e-9 {
                continue
            }

            let prevDir = directionFrom[node] ?? nil

            // Explore neighbors: 4 planar directions + 1 layer change
            for dir in Direction.allCases {
                let (nr, nc) = neighbor(node.row, node.col, dir)
                guard nr >= 0, nr < congestion.rows, nc >= 0, nc < congestion.cols else { continue }

                let neighborNode = Node3D(row: nr, col: nc, layer: node.layer)
                let isH = (dir == .east || dir == .west)
                let layerID = node.layer == 0 ? layers.m1 : layers.m2
                let width = node.layer == 0 ? m1Width : m2Width
                let spacing = node.layer == 0 ? m1Spacing : m2Spacing

                // Check obstruction at the neighbor cell
                let neighborCenter = congestion.layoutPoint(row: nr, col: nc)
                let probeRect = LayoutRect(
                    origin: LayoutPoint(
                        x: neighborCenter.x - width / 2,
                        y: neighborCenter.y - width / 2
                    ),
                    size: LayoutSize(width: width, height: width)
                )
                if obstMap.hasCollision(rect: probeRect, layer: layerID, spacing: spacing) {
                    continue
                }

                // Compute edge cost
                var edgeCost = costConfig.baseCellCost
                edgeCost += congestion.cellCostWithHistory(
                    row: nr, col: nc,
                    isHorizontal: isH,
                    historyFactor: costConfig.historyFactor,
                    presentPenalty: costConfig.presentPenalty
                )

                // Wrong-way penalty: horizontal on M2 or vertical on M1
                let preferredH = (node.layer == 0)  // M1 prefers horizontal
                if isH != preferredH {
                    edgeCost += costConfig.wrongWayPenalty
                }

                // Bend penalty: direction change
                if let pd = prevDir, pd != dir {
                    edgeCost += costConfig.bendPenalty
                }

                let tentativeG = current.gCost + edgeCost
                if tentativeG < (gScores[neighborNode] ?? .infinity) {
                    gScores[neighborNode] = tentativeG
                    cameFrom[neighborNode] = node
                    directionFrom[neighborNode] = dir
                    let h = heuristic(nr, nc, goalRow, goalCol)
                    openSet.insert(PQEntry(node: neighborNode, fCost: tentativeG + h, gCost: tentativeG))
                }
            }

            // Layer change (via): stay at same (row, col), toggle layer
            let otherLayer = 1 - node.layer
            let viaNode = Node3D(row: node.row, col: node.col, layer: otherLayer)
            let viaCost = current.gCost + costConfig.viaPenalty
            if viaCost < (gScores[viaNode] ?? .infinity) {
                gScores[viaNode] = viaCost
                cameFrom[viaNode] = node
                directionFrom[viaNode] = prevDir  // preserve direction through via
                let h = heuristic(node.row, node.col, goalRow, goalCol)
                openSet.insert(PQEntry(node: viaNode, fCost: viaCost + h, gCost: viaCost))
            }
        }

        // No path found
        return nil
    }

    // MARK: - Heuristic

    private func heuristic(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) -> Double {
        Double(abs(r1 - r2) + abs(c1 - c2))
    }

    // MARK: - Neighbor

    private func neighbor(_ row: Int, _ col: Int, _ dir: Direction) -> (Int, Int) {
        switch dir {
        case .north: return (row + 1, col)
        case .south: return (row - 1, col)
        case .east:  return (row, col + 1)
        case .west:  return (row, col - 1)
        }
    }

    // MARK: - Path Reconstruction

    private func reconstructPath(
        cameFrom: [Node3D: Node3D],
        end: Node3D,
        congestion: CongestionGrid,
        layers: (m1: LayoutLayerID, m2: LayoutLayerID),
        m1Width: Double,
        m2Width: Double
    ) -> [ChannelRouter.RouteSegment] {
        // Trace back through the path
        var path: [Node3D] = [end]
        var current = end
        while let prev = cameFrom[current] {
            path.append(prev)
            current = prev
        }
        path.reverse()

        guard path.count >= 2 else { return [] }

        // Convert consecutive same-layer, same-direction moves into segments
        var segments: [ChannelRouter.RouteSegment] = []
        var segStart = 0

        for i in 1..<path.count {
            let prev = path[i - 1]
            let curr = path[i]

            let isLayerChange = prev.layer != curr.layer
            let isLastNode = (i == path.count - 1)

            // Determine if we should end the current segment
            let shouldEnd: Bool
            if isLayerChange {
                shouldEnd = true
            } else if isLastNode {
                shouldEnd = true
            } else {
                // Check if direction changes at next step
                let next = path[i + 1]
                let currIsH = (curr.col != prev.col && curr.row == prev.row)
                let nextIsH = (next.col != curr.col && next.row == curr.row)
                let nextIsLayerChange = (next.layer != curr.layer)
                shouldEnd = (currIsH != nextIsH) || nextIsLayerChange
            }

            if shouldEnd {
                let startNode = path[segStart]
                let endNode: Node3D
                if isLayerChange {
                    // For layer changes, the segment ends at prev
                    endNode = prev
                } else {
                    endNode = curr
                }

                // Only emit a segment if start != end (skip zero-length)
                if startNode.row != endNode.row || startNode.col != endNode.col {
                    let fromPt = congestion.layoutPoint(row: startNode.row, col: startNode.col)
                    let toPt = congestion.layoutPoint(row: endNode.row, col: endNode.col)
                    let isH = (startNode.row == endNode.row)
                    let layer = startNode.layer == 0 ? layers.m1 : layers.m2
                    let width = startNode.layer == 0 ? m1Width : m2Width

                    segments.append(ChannelRouter.RouteSegment(
                        layer: layer,
                        from: fromPt,
                        to: toPt,
                        width: width,
                        isHorizontal: isH
                    ))
                }

                if isLayerChange {
                    // Start new segment from curr after layer change
                    segStart = i
                } else {
                    segStart = i
                }
            }
        }

        return segments
    }
}

// MARK: - MinHeap (Binary Heap Priority Queue)

/// Simple binary min-heap for A* priority queue.
private struct MinHeap<Element: Comparable>: Sendable where Element: Sendable {
    private var storage: [Element] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func insert(_ element: Element) {
        storage.append(element)
        siftUp(storage.count - 1)
    }

    mutating func extractMin() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let min = storage[0]
        storage[0] = storage.removeLast()
        siftDown(0)
        return min
    }

    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i] < storage[parent] {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        let count = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < count && storage[left] < storage[smallest] {
                smallest = left
            }
            if right < count && storage[right] < storage[smallest] {
                smallest = right
            }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
