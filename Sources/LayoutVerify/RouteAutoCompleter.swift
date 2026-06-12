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

        public init(
            start: LayoutPoint,
            target: LayoutPoint,
            window: LayoutRect,
            obstacles: [LayoutRect],
            clearance: Double,
            step: Double
        ) {
            self.start = start
            self.target = target
            self.window = window
            self.obstacles = obstacles
            self.clearance = clearance
            self.step = step
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

        guard let startNode = node(nearest: request.start),
              let targetNode = node(nearest: request.target),
              !blocked(startNode.column, startNode.row),
              !blocked(targetNode.column, targetNode.row) else {
            return nil
        }

        // BFS with parent reconstruction.
        var parent = [Int32](repeating: -2, count: columns * rows)
        func index(_ column: Int, _ row: Int) -> Int { row * columns + column }
        var queue: [Int] = [index(startNode.column, startNode.row)]
        parent[queue[0]] = -1
        let targetIndex = index(targetNode.column, targetNode.row)
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == targetIndex { break }
            let column = current % columns
            let row = current / columns
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nc = column + dc
                let nr = row + dr
                guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                let next = index(nc, nr)
                guard parent[next] == -2, !blocked(nc, nr) else { continue }
                parent[next] = Int32(current)
                queue.append(next)
            }
        }
        guard parent[targetIndex] != -2 else { return nil }

        var indices: [Int] = []
        var cursor = targetIndex
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
        corners.append(request.target)
        return corners
    }
}
