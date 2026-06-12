import Foundation
import LayoutCore

/// Window-local orthogonal path search for route auto-complete.
///
/// A plain Lee/BFS over a uniform lattice inside `window`: nodes whose
/// clearance envelope touches an obstacle are blocked, the shortest
/// 4-connected path is compressed to its corners. The search NEVER
/// widens the window on its own — no path inside the window returns
/// nil and the caller reports the miss, so a long detour outside the
/// viewport cannot appear silently.
public struct RouteAutoCompleter: Sendable {

    public struct Request: Sendable {
        public var start: LayoutPoint
        public var target: LayoutPoint
        public var window: LayoutRect
        /// Foreign-geometry bounding boxes the path must clear.
        public var obstacles: [LayoutRect]
        /// Required distance from the wire CENTERLINE to any obstacle
        /// edge: half the wire width plus the layer's minimum spacing.
        public var clearance: Double
        /// Lattice pitch in microns.
        public var step: Double
        /// Boxes of the target island's same-layer members: reaching ANY
        /// clear lattice node inside one of them completes the path even
        /// when the exact `target` point is clearance-blocked by foreign
        /// geometry — landing anywhere on the island connects the net.
        /// Empty means the exact `target` node is the only goal.
        public var targetRegion: [LayoutRect]

        public init(
            start: LayoutPoint,
            target: LayoutPoint,
            window: LayoutRect,
            obstacles: [LayoutRect],
            clearance: Double,
            step: Double,
            targetRegion: [LayoutRect] = []
        ) {
            self.start = start
            self.target = target
            self.window = window
            self.obstacles = obstacles
            self.clearance = clearance
            self.step = step
            self.targetRegion = targetRegion
        }
    }

    public init() {}

    /// Corner points of the shortest clear path from `start` to `target`
    /// (both included), or nil when the window holds no clear path.
    public func findPath(_ request: Request) -> [LayoutPoint]? {
        let step = max(request.step, 1e-3)
        let columns = Int((request.window.size.width / step).rounded(.down)) + 1
        let rows = Int((request.window.size.height / step).rounded(.down)) + 1
        guard columns > 1, rows > 1, columns * rows <= 4_000_000 else { return nil }

        let inflated = request.obstacles.map {
            $0.expanded(by: request.clearance, request.clearance)
        }

        func point(of column: Int, _ row: Int) -> LayoutPoint {
            LayoutPoint(
                x: request.window.minX + Double(column) * step,
                y: request.window.minY + Double(row) * step
            )
        }
        func node(nearest point: LayoutPoint) -> (column: Int, row: Int)? {
            let column = Int(((point.x - request.window.minX) / step).rounded())
            let row = Int(((point.y - request.window.minY) / step).rounded())
            guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
            return (column, row)
        }
        func blocked(_ column: Int, _ row: Int) -> Bool {
            let p = point(of: column, row)
            for box in inflated where box.contains(p) {
                return true
            }
            return false
        }

        func index(_ column: Int, _ row: Int) -> Int { row * columns + column }

        guard let startNode = node(nearest: request.start),
              !blocked(startNode.column, startNode.row) else {
            return nil
        }
        let targetIndex: Int
        if let targetNode = node(nearest: request.target),
           !blocked(targetNode.column, targetNode.row) {
            targetIndex = index(targetNode.column, targetNode.row)
        } else if request.targetRegion.isEmpty {
            return nil
        } else {
            targetIndex = -1
        }
        func isGoal(_ current: Int) -> Bool {
            if current == targetIndex { return true }
            guard !request.targetRegion.isEmpty else { return false }
            let p = point(of: current % columns, current / columns)
            return request.targetRegion.contains { $0.contains(p) }
        }

        // BFS with parent reconstruction; the first goal node dequeued
        // ends the shortest path.
        var parent = [Int32](repeating: -2, count: columns * rows)
        var queue: [Int] = [index(startNode.column, startNode.row)]
        parent[queue[0]] = -1
        var goalIndex: Int? = isGoal(queue[0]) ? queue[0] : nil
        var head = 0
        while goalIndex == nil, head < queue.count {
            let current = queue[head]
            head += 1
            let column = current % columns
            let row = current / columns
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nc = column + dc
                let nr = row + dr
                guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                let next = index(nc, nr)
                guard parent[next] == -2, !blocked(nc, nr) else { continue }
                parent[next] = Int32(current)
                if isGoal(next) {
                    goalIndex = next
                    break
                }
                queue.append(next)
            }
        }
        guard let reached = goalIndex else { return nil }

        var indices: [Int] = []
        var cursor = reached
        while cursor != -1 {
            indices.append(cursor)
            cursor = Int(parent[cursor])
        }
        indices.reverse()

        // Compress collinear runs to corners and pin the exact endpoints.
        var corners: [LayoutPoint] = [request.start]
        for position in 1..<max(indices.count - 1, 1) {
            let previous = indices[position - 1]
            let current = indices[position]
            let next = indices[position + 1]
            let straight = (previous % columns == next % columns)
                || (previous / columns == next / columns)
            if !straight {
                corners.append(point(of: current % columns, current / columns))
            }
        }
        // Pin the exact target only when the search ended on its node; a
        // region landing ends at the lattice point that actually reached
        // the island.
        if reached == targetIndex {
            corners.append(request.target)
        } else {
            corners.append(point(of: reached % columns, reached / columns))
        }
        return corners
    }
}
