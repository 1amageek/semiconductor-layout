import Foundation
import LayoutCore

/// Tracks occupied regions per layer for routing obstruction detection.
///
/// Uses simple bounding-box overlap checking. Each registered shape is stored
/// as an indexed rect on its layer. Supports removal by shape ID for rip-up/reroute.
public struct ObstructionMap: Sendable {

    private struct IndexedRect: Sendable {
        let shapeID: UUID
        let rect: LayoutRect
    }

    private var obstructions: [String: [IndexedRect]]  // layerKey → indexed rects
    private var shapeLayerIndex: [UUID: String]         // shapeID → layerKey (for removal)

    public init() {
        obstructions = [:]
        shapeLayerIndex = [:]
    }

    /// Registers a shape and returns its assigned shape ID for later removal.
    @discardableResult
    public mutating func register(shape: LayoutShape) -> UUID {
        let key = layerKey(shape.layer)
        let bounds = geometryBounds(shape.geometry)
        let shapeID = UUID()
        obstructions[key, default: []].append(IndexedRect(shapeID: shapeID, rect: bounds))
        shapeLayerIndex[shapeID] = key
        return shapeID
    }

    /// Registers a rect on a layer and returns its assigned shape ID.
    @discardableResult
    public mutating func register(rect: LayoutRect, layer: LayoutLayerID) -> UUID {
        let key = layerKey(layer)
        let shapeID = UUID()
        obstructions[key, default: []].append(IndexedRect(shapeID: shapeID, rect: rect))
        shapeLayerIndex[shapeID] = key
        return shapeID
    }

    /// Removes a previously registered shape by its ID.
    public mutating func remove(shapeID: UUID) {
        guard let key = shapeLayerIndex.removeValue(forKey: shapeID) else { return }
        obstructions[key]?.removeAll { $0.shapeID == shapeID }
    }

    /// Removes all shapes associated with a collection of shape IDs.
    public mutating func remove(shapeIDs: [UUID]) {
        for id in shapeIDs {
            remove(shapeID: id)
        }
    }

    public func hasCollision(rect: LayoutRect, layer: LayoutLayerID, spacing: Double) -> Bool {
        let key = layerKey(layer)
        guard let rects = obstructions[key] else { return false }
        let expanded = rect.expanded(by: spacing, spacing)
        return rects.contains { $0.rect.intersects(expanded) }
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
