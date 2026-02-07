import Foundation
import LayoutCore

/// Tracks occupied regions per layer for routing obstruction detection.
///
/// Uses simple bounding-box overlap checking. Each registered shape is stored
/// as a LayoutRect on its layer. Collision checks inflate query rects by the
/// required minimum spacing.
public struct ObstructionMap: Sendable {
    private var obstructions: [String: [LayoutRect]]  // layerKey → rects

    public init() {
        obstructions = [:]
    }

    public mutating func register(shape: LayoutShape) {
        let key = layerKey(shape.layer)
        let bounds = geometryBounds(shape.geometry)
        obstructions[key, default: []].append(bounds)
    }

    public mutating func register(rect: LayoutRect, layer: LayoutLayerID) {
        let key = layerKey(layer)
        obstructions[key, default: []].append(rect)
    }

    public func hasCollision(rect: LayoutRect, layer: LayoutLayerID, spacing: Double) -> Bool {
        let key = layerKey(layer)
        guard let rects = obstructions[key] else { return false }
        let expanded = rect.expanded(by: spacing, spacing)
        return rects.contains { $0.intersects(expanded) }
    }

    private func layerKey(_ layer: LayoutLayerID) -> String {
        "\(layer.name):\(layer.purpose)"
    }

    private func geometryBounds(_ geometry: LayoutGeometry) -> LayoutRect {
        switch geometry {
        case .rect(let r):
            return r
        case .polygon(let p):
            guard let first = p.points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x)
                minY = min(minY, pt.y)
                maxX = max(maxX, pt.x)
                maxY = max(maxY, pt.y)
            }
            return LayoutRect(
                origin: LayoutPoint(x: minX, y: minY),
                size: LayoutSize(width: maxX - minX, height: maxY - minY)
            )
        case .path(let p):
            guard let first = p.points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for pt in p.points.dropFirst() {
                minX = min(minX, pt.x)
                minY = min(minY, pt.y)
                maxX = max(maxX, pt.x)
                maxY = max(maxY, pt.y)
            }
            let hw = p.width / 2
            return LayoutRect(
                origin: LayoutPoint(x: minX - hw, y: minY - hw),
                size: LayoutSize(width: maxX - minX + p.width, height: maxY - minY + p.width)
            )
        }
    }
}
