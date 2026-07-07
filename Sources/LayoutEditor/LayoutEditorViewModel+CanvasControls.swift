import SwiftUI
import LayoutCore
import LayoutTech

extension LayoutEditorViewModel {
    // MARK: - Layer Visibility

    public func isLayerVisible(_ layer: LayoutLayerID) -> Bool {
        !hiddenLayers.contains(layer)
    }

    public func toggleLayerVisibility(_ layer: LayoutLayerID) {
        if hiddenLayers.contains(layer) {
            hiddenLayers.remove(layer)
        } else {
            hiddenLayers.insert(layer)
        }
    }

    // MARK: - Angle-Constrained Snap

    /// Applies grid snap and then angle constraint relative to an anchor point.
    public func constrainedSnap(_ point: LayoutPoint, from anchor: LayoutPoint?) -> LayoutPoint {
        let gridSnapped = snapToGrid(point)
        guard let anchor else { return gridSnapped }
        return angleConstraint.snap(gridSnapped, from: anchor)
    }

    // MARK: - Zoom Steps

    public static let zoomSteps: [CGFloat] = [
        0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50,
        100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000
    ]

    public func zoomToStep(_ step: CGFloat) {
        let clamped = max(0.01, min(100000, step))
        let oldZoom = zoom
        guard oldZoom > 0 else { zoom = clamped; return }
        let scale = clamped / oldZoom
        offset = CGPoint(
            x: canvasSize.width / 2 - (canvasSize.width / 2 - offset.x) * scale,
            y: canvasSize.height / 2 - (canvasSize.height / 2 - offset.y) * scale
        )
        zoom = clamped
    }

    public func zoomInStep() {
        if let next = Self.zoomSteps.first(where: { $0 > zoom * 1.01 }) {
            zoomToStep(next)
        }
    }

    public func zoomOutStep() {
        if let prev = Self.zoomSteps.last(where: { $0 < zoom * 0.99 }) {
            zoomToStep(prev)
        }
    }

    // MARK: - Grid Snap

    public func snapToGrid(_ point: LayoutPoint) -> LayoutPoint {
        let g = gridSize
        guard g > 0 else { return point }
        return LayoutPoint(
            x: (point.x / g).rounded() * g,
            y: (point.y / g).rounded() * g
        )
    }

}
