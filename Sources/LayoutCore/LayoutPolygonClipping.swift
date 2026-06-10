import Foundation

// MARK: - Polygon Boolean Operations (Sutherland-Hodgman based)

extension LayoutPolygon {

    /// Clips this polygon to the inside of the given rectangle.
    /// Returns the intersection polygon, or nil if fully outside.
    public func clipped(to rect: LayoutRect) -> LayoutPolygon? {
        var pts = points
        guard !pts.isEmpty else { return nil }

        // Clip against each edge of the rectangle (Sutherland-Hodgman)
        pts = clipByEdge(pts, edge: .left(rect.minX))
        pts = clipByEdge(pts, edge: .right(rect.maxX))
        pts = clipByEdge(pts, edge: .bottom(rect.minY))
        pts = clipByEdge(pts, edge: .top(rect.maxY))

        guard pts.count >= 3 else { return nil }
        return LayoutPolygon(points: pts)
    }

    /// Subtracts `cut` rectangle from this polygon.
    ///
    /// For interior holes (cut fully inside polygon), produces a single keyhole polygon
    /// with a zero-width bridge connecting the outer boundary to the hole.
    /// For partial overlaps, traces the difference boundary to produce minimal polygons.
    public func subtract(cut: LayoutRect) -> [LayoutPolygon] {
        let poly = self.ensureCounterClockwise()
        let n = poly.points.count
        guard n >= 3 else { return [] }

        let bbox = LayoutGeometryAnalysis.boundingBox(for: poly)
        guard bbox.intersects(cut) else { return [self] }

        // Clip cut to polygon's bounding box to avoid tracing far outside
        let clippedCut = LayoutRect(
            origin: LayoutPoint(x: max(cut.minX, bbox.minX), y: max(cut.minY, bbox.minY)),
            size: LayoutSize(
                width: min(cut.maxX, bbox.maxX) - max(cut.minX, bbox.minX),
                height: min(cut.maxY, bbox.maxY) - max(cut.minY, bbox.minY)
            )
        )
        guard clippedCut.size.width > 1e-9 && clippedCut.size.height > 1e-9 else { return [self] }

        // Find all intersection points between polygon edges and rectangle edges
        var crossings: [SubtractCrossing] = []
        for i in 0..<n {
            let a = poly.points[i]
            let b = poly.points[(i + 1) % n]
            let edgeBase = Double(i)

            if let t = Self.segVert(a: a, b: b, x: clippedCut.minX, yMin: clippedCut.minY, yMax: clippedCut.maxY) {
                crossings.append(SubtractCrossing(point: Self.lerp(a, b, t), polyParam: edgeBase + t))
            }
            if let t = Self.segVert(a: a, b: b, x: clippedCut.maxX, yMin: clippedCut.minY, yMax: clippedCut.maxY) {
                crossings.append(SubtractCrossing(point: Self.lerp(a, b, t), polyParam: edgeBase + t))
            }
            if let t = Self.segHoriz(a: a, b: b, y: clippedCut.minY, xMin: clippedCut.minX, xMax: clippedCut.maxX) {
                crossings.append(SubtractCrossing(point: Self.lerp(a, b, t), polyParam: edgeBase + t))
            }
            if let t = Self.segHoriz(a: a, b: b, y: clippedCut.maxY, xMin: clippedCut.minX, xMax: clippedCut.maxX) {
                crossings.append(SubtractCrossing(point: Self.lerp(a, b, t), polyParam: edgeBase + t))
            }
        }

        crossings.sort { $0.polyParam < $1.polyParam }
        crossings = Self.dedup(crossings)

        if crossings.isEmpty {
            let cutCenter = LayoutPoint(
                x: (clippedCut.minX + clippedCut.maxX) / 2,
                y: (clippedCut.minY + clippedCut.maxY) / 2
            )
            if LayoutGeometryAnalysis.contains(cutCenter, in: poly) {
                // Interior hole → keyhole polygon
                return [Self.makeKeyhole(outer: poly, hole: clippedCut)]
            }
            if clippedCut.contains(poly.points[0]) {
                return []
            }
            return [self]
        }

        // Odd number of crossings → degenerate geometry, fallback
        guard crossings.count % 2 == 0 else { return [self] }

        // Classify entering/leaving
        let firstInside = Self.strictlyInside(poly.points[0], rect: clippedCut)
        var entering = !firstInside
        for i in 0..<crossings.count {
            crossings[i].isEntering = entering
            entering.toggle()
        }

        return Self.traceBoundary(poly: poly, cut: clippedCut, crossings: crossings)
    }

    // MARK: - Keyhole Polygon

    /// Creates a keyhole polygon: outer boundary CCW with a zero-width bridge to
    /// the hole, hole boundary CW, bridge back. Renders correctly with nonzero winding fill.
    private static func makeKeyhole(outer: LayoutPolygon, hole: LayoutRect) -> LayoutPolygon {
        let bridgeY = hole.minY
        let n = outer.points.count

        // Find the outer polygon edge intersected by a leftward horizontal ray from hole's bottom-left
        var bestX = -Double.greatestFiniteMagnitude
        var bestEdge = -1

        for i in 0..<n {
            let a = outer.points[i]
            let b = outer.points[(i + 1) % n]
            let dy = b.y - a.y
            guard abs(dy) > 1e-12 else { continue }
            let t = (bridgeY - a.y) / dy
            guard t > 1e-9 && t < 1 - 1e-9 else { continue }
            let x = a.x + t * (b.x - a.x)
            guard x < hole.minX - 1e-9 else { continue }
            if x > bestX {
                bestX = x
                bestEdge = i
            }
        }

        guard bestEdge >= 0 else { return outer }

        let bridgePoint = LayoutPoint(x: bestX, y: bridgeY)
        let holeBL = LayoutPoint(x: hole.minX, y: hole.minY)
        let holeTL = LayoutPoint(x: hole.minX, y: hole.maxY)
        let holeTR = LayoutPoint(x: hole.maxX, y: hole.maxY)
        let holeBR = LayoutPoint(x: hole.maxX, y: hole.minY)

        // Build: outer[0..bestEdge], bridgePoint, hole CW, bridgePoint, outer[bestEdge+1..n-1]
        var result: [LayoutPoint] = []
        for i in 0...bestEdge {
            result.append(outer.points[i])
        }
        result.append(bridgePoint)
        // Hole CW: BL → TL → TR → BR → BL
        result.append(holeBL)
        result.append(holeTL)
        result.append(holeTR)
        result.append(holeBR)
        result.append(holeBL)
        // Bridge back
        result.append(bridgePoint)
        for i in (bestEdge + 1)..<n {
            result.append(outer.points[i])
        }
        return LayoutPolygon(points: result)
    }

    // MARK: - Boundary Tracing

    /// Traces the difference boundary (polygon minus rectangle) using entering/leaving crossings.
    private static func traceBoundary(
        poly: LayoutPolygon, cut: LayoutRect, crossings: [SubtractCrossing]
    ) -> [LayoutPolygon] {
        let n = poly.points.count
        let nc = crossings.count
        var visited = [Bool](repeating: false, count: nc)
        var results: [LayoutPolygon] = []

        for startSearch in 0..<nc {
            // Find the next unvisited "leaving" crossing
            guard !visited[startSearch], !crossings[startSearch].isEntering else { continue }

            var path: [LayoutPoint] = []
            var idx = startSearch

            while true {
                let leavingIdx = idx
                let enteringIdx = (leavingIdx + 1) % nc
                visited[leavingIdx] = true
                visited[enteringIdx] = true

                // Trace polygon boundary from leaving → entering
                path.append(crossings[leavingIdx].point)
                let startP = crossings[leavingIdx].polyParam
                let rawEndP = crossings[enteringIdx].polyParam
                let endP = rawEndP > startP + 1e-9 ? rawEndP : rawEndP + Double(n)

                var vi = Int(ceil(startP))
                if abs(Double(vi) - startP) < 1e-9 { vi += 1 }
                while Double(vi) < endP - 1e-9 {
                    path.append(poly.points[vi % n])
                    vi += 1
                }
                path.append(crossings[enteringIdx].point)

                // Trace rect boundary CW from entering → next leaving
                let nextLeavingIdx = (enteringIdx + 1) % nc
                addRectCW(
                    from: crossings[enteringIdx].point,
                    to: crossings[nextLeavingIdx].point,
                    cut: cut,
                    path: &path
                )

                idx = nextLeavingIdx
                if idx == startSearch { break }
            }

            let cleaned = removeDupConsecutive(path)
            if cleaned.count >= 3 {
                results.append(LayoutPolygon(points: cleaned))
            }
        }

        return results.isEmpty ? [LayoutPolygon(points: poly.points)] : results
    }

    // MARK: - Rectangle CW Tracing

    /// Parameterizes a point on the rectangle boundary in CW order [0,4).
    /// CW: BL(0) → TL(1) → TR(2) → BR(3).
    private static func rectParamCW(_ p: LayoutPoint, cut: LayoutRect) -> Double {
        let eps = 1e-6
        let w = max(cut.maxX - cut.minX, eps)
        let h = max(cut.maxY - cut.minY, eps)

        // Left edge: x ≈ minX, param [0,1]
        if abs(p.x - cut.minX) < eps {
            return clamp01((p.y - cut.minY) / h)
        }
        // Top edge: y ≈ maxY, param [1,2]
        if abs(p.y - cut.maxY) < eps {
            return 1.0 + clamp01((p.x - cut.minX) / w)
        }
        // Right edge: x ≈ maxX, param [2,3]
        if abs(p.x - cut.maxX) < eps {
            return 2.0 + clamp01((cut.maxY - p.y) / h)
        }
        // Bottom edge: y ≈ minY, param [3,4]
        if abs(p.y - cut.minY) < eps {
            return 3.0 + clamp01((cut.maxX - p.x) / w)
        }
        return 0
    }

    private static func clamp01(_ v: Double) -> Double {
        min(max(v, 0), 1)
    }

    /// Adds rectangle corner points between `from` and `to` in CW order.
    private static func addRectCW(
        from start: LayoutPoint, to end: LayoutPoint, cut: LayoutRect, path: inout [LayoutPoint]
    ) {
        let startP = rectParamCW(start, cut: cut)
        var endP = rectParamCW(end, cut: cut)
        if endP <= startP + 1e-9 { endP += 4.0 }

        // CW corners: 0=BL, 1=TL, 2=TR, 3=BR
        let corners = [
            LayoutPoint(x: cut.minX, y: cut.minY),
            LayoutPoint(x: cut.minX, y: cut.maxY),
            LayoutPoint(x: cut.maxX, y: cut.maxY),
            LayoutPoint(x: cut.maxX, y: cut.minY),
        ]
        // Check params 0..7 to handle wrap-around
        for i in 0..<8 {
            let cp = Double(i)
            if cp > startP + 1e-9 && cp < endP - 1e-9 {
                path.append(corners[i % 4])
            }
        }
    }

    // MARK: - Intersection Helpers

    private struct SubtractCrossing {
        let point: LayoutPoint
        let polyParam: Double
        var isEntering: Bool = false
    }

    private static func segVert(a: LayoutPoint, b: LayoutPoint, x: Double, yMin: Double, yMax: Double) -> Double? {
        let dx = b.x - a.x
        guard abs(dx) > 1e-12 else { return nil }
        let t = (x - a.x) / dx
        guard t > 1e-9 && t < 1 - 1e-9 else { return nil }
        let y = a.y + t * (b.y - a.y)
        guard y >= yMin - 1e-9 && y <= yMax + 1e-9 else { return nil }
        return t
    }

    private static func segHoriz(a: LayoutPoint, b: LayoutPoint, y: Double, xMin: Double, xMax: Double) -> Double? {
        let dy = b.y - a.y
        guard abs(dy) > 1e-12 else { return nil }
        let t = (y - a.y) / dy
        guard t > 1e-9 && t < 1 - 1e-9 else { return nil }
        let x = a.x + t * (b.x - a.x)
        guard x >= xMin - 1e-9 && x <= xMax + 1e-9 else { return nil }
        return t
    }

    private static func lerp(_ a: LayoutPoint, _ b: LayoutPoint, _ t: Double) -> LayoutPoint {
        LayoutPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
    }

    private static func strictlyInside(_ p: LayoutPoint, rect: LayoutRect) -> Bool {
        p.x > rect.minX + 1e-9 && p.x < rect.maxX - 1e-9 &&
        p.y > rect.minY + 1e-9 && p.y < rect.maxY - 1e-9
    }

    private static func dedup(_ crossings: [SubtractCrossing]) -> [SubtractCrossing] {
        guard !crossings.isEmpty else { return [] }
        var result = [crossings[0]]
        for i in 1..<crossings.count {
            let prev = result.last!
            let curr = crossings[i]
            if abs(curr.polyParam - prev.polyParam) > 1e-9 {
                result.append(curr)
            }
        }
        return result
    }

    private static func removeDupConsecutive(_ points: [LayoutPoint]) -> [LayoutPoint] {
        guard !points.isEmpty else { return [] }
        var result = [points[0]]
        for i in 1..<points.count {
            let p = points[i]
            let prev = result.last!
            if abs(p.x - prev.x) > 1e-9 || abs(p.y - prev.y) > 1e-9 {
                result.append(p)
            }
        }
        // Remove if last == first
        if result.count > 1, let first = result.first, let last = result.last,
           abs(first.x - last.x) < 1e-9 && abs(first.y - last.y) < 1e-9 {
            result.removeLast()
        }
        return result
    }

    /// Splits this polygon vertically at the given x coordinate.
    /// Returns `(left, right)` or nil if x is outside the polygon bounding box.
    public func splitVertically(at x: Double) -> (LayoutPolygon, LayoutPolygon)? {
        let bbox = LayoutGeometryAnalysis.boundingBox(for: self)
        guard x > bbox.minX, x < bbox.maxX else { return nil }

        let leftRect = LayoutRect(
            origin: bbox.origin,
            size: LayoutSize(width: x - bbox.minX, height: bbox.size.height)
        )
        let rightRect = LayoutRect(
            origin: LayoutPoint(x: x, y: bbox.origin.y),
            size: LayoutSize(width: bbox.maxX - x, height: bbox.size.height)
        )

        guard let left = clipped(to: leftRect),
              let right = clipped(to: rightRect) else { return nil }
        return (left, right)
    }

    /// Splits this polygon horizontally at the given y coordinate.
    /// Returns `(bottom, top)` or nil if y is outside the polygon bounding box.
    public func splitHorizontally(at y: Double) -> (LayoutPolygon, LayoutPolygon)? {
        let bbox = LayoutGeometryAnalysis.boundingBox(for: self)
        guard y > bbox.minY, y < bbox.maxY else { return nil }

        let bottomRect = LayoutRect(
            origin: bbox.origin,
            size: LayoutSize(width: bbox.size.width, height: y - bbox.minY)
        )
        let topRect = LayoutRect(
            origin: LayoutPoint(x: bbox.origin.x, y: y),
            size: LayoutSize(width: bbox.size.width, height: bbox.maxY - y)
        )

        guard let bottom = clipped(to: bottomRect),
              let top = clipped(to: topRect) else { return nil }
        return (bottom, top)
    }

    // MARK: - Sutherland-Hodgman Single-Edge Clipping

    private enum ClipEdge {
        case left(Double)
        case right(Double)
        case bottom(Double)
        case top(Double)

        func isInside(_ p: LayoutPoint) -> Bool {
            switch self {
            case .left(let x): return p.x >= x
            case .right(let x): return p.x <= x
            case .bottom(let y): return p.y >= y
            case .top(let y): return p.y <= y
            }
        }
    }

    private func clipByEdge(_ polygon: [LayoutPoint], edge: ClipEdge) -> [LayoutPoint] {
        guard !polygon.isEmpty else { return [] }
        var output: [LayoutPoint] = []
        var prev = polygon[polygon.count - 1]
        var prevInside = edge.isInside(prev)

        for current in polygon {
            let currentInside = edge.isInside(current)
            if currentInside {
                if !prevInside {
                    if let inter = intersection(prev, current, edge: edge) {
                        output.append(inter)
                    }
                }
                output.append(current)
            } else if prevInside {
                if let inter = intersection(prev, current, edge: edge) {
                    output.append(inter)
                }
            }
            prev = current
            prevInside = currentInside
        }
        return output
    }

    private func intersection(_ a: LayoutPoint, _ b: LayoutPoint, edge: ClipEdge) -> LayoutPoint? {
        let dx = b.x - a.x
        let dy = b.y - a.y

        switch edge {
        case .left(let x):
            guard abs(dx) > 1e-12 else { return nil }
            let t = (x - a.x) / dx
            return LayoutPoint(x: x, y: a.y + t * dy)
        case .right(let x):
            guard abs(dx) > 1e-12 else { return nil }
            let t = (x - a.x) / dx
            return LayoutPoint(x: x, y: a.y + t * dy)
        case .bottom(let y):
            guard abs(dy) > 1e-12 else { return nil }
            let t = (y - a.y) / dy
            return LayoutPoint(x: a.x + t * dx, y: y)
        case .top(let y):
            guard abs(dy) > 1e-12 else { return nil }
            let t = (y - a.y) / dy
            return LayoutPoint(x: a.x + t * dx, y: y)
        }
    }
}

// MARK: - Signed Area and Winding

extension LayoutPolygon {
    /// Signed area (positive = CCW, negative = CW).
    public var signedArea: Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            sum += (p1.x * p2.y - p2.x * p1.y)
        }
        return sum * 0.5
    }

    /// Ensures CCW winding order.
    public func ensureCounterClockwise() -> LayoutPolygon {
        if signedArea < 0 {
            return LayoutPolygon(points: points.reversed())
        }
        return self
    }
}
