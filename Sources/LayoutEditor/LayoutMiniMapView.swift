import SwiftUI
import LayoutCore
import LayoutTech

/// A miniature overview of the layout, showing all content and the current viewport.
/// Click or drag on the minimap to navigate the main canvas.
struct LayoutMiniMapView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    private let miniMapSize = CGSize(width: 180, height: 120)
    private let padding: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let viewport = currentViewport
            let worldRect = computeWorldRect(viewport: viewport)
            guard worldRect.width > 0, worldRect.height > 0 else {
                drawEmptyCrosshair(in: &context, size: size)
                return
            }

            let hasContent = viewModel.renderContentBounds != nil
            if hasContent {
                drawShapes(in: &context, size: size, worldRect: worldRect)
                drawInstances(in: &context, size: size, worldRect: worldRect)
            } else {
                drawEmptyCrosshair(in: &context, size: size)
            }
            drawViewport(in: &context, viewport: viewport, size: size, worldRect: worldRect)
        }
        .frame(width: miniMapSize.width, height: miniMapSize.height)
        .gesture(navigationGesture)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - World Rect

    private var currentViewport: CGRect {
        let canvasSize = viewModel.canvasSize
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 400, height: 300)
        }
        return CGRect(
            x: -Double(viewModel.offset.x / viewModel.zoom),
            y: -Double(viewModel.offset.y / viewModel.zoom),
            width: Double(canvasSize.width / viewModel.zoom),
            height: Double(canvasSize.height / viewModel.zoom)
        )
    }

    private func computeWorldRect(viewport: CGRect) -> CGRect {
        let base: CGRect
        // The render index's occupied-cell bounds are an O(1) over-
        // approximation by at most one grid cell per side — exactly the
        // tolerance an overview already hides inside its 15% margin —
        // where `contentBounds()` would flatten the whole database every
        // frame.
        if let contentBounds = viewModel.renderContentBounds {
            let contentRect = CGRect(
                x: contentBounds.origin.x,
                y: contentBounds.origin.y,
                width: contentBounds.size.width,
                height: contentBounds.size.height
            )
            base = contentRect.union(viewport)
        } else {
            base = viewport
        }
        let marginX = base.width * 0.15
        let marginY = base.height * 0.15
        return base.insetBy(dx: -marginX, dy: -marginY)
    }

    // MARK: - Projection

    private func worldToMiniMap(_ point: CGPoint, size: CGSize, worldRect: CGRect) -> CGPoint {
        let scaleX = (size.width - padding * 2) / worldRect.width
        let scaleY = (size.height - padding * 2) / worldRect.height
        let scale = min(scaleX, scaleY)
        let offsetX = (size.width - worldRect.width * scale) / 2
        let offsetY = (size.height - worldRect.height * scale) / 2
        return CGPoint(
            x: (point.x - worldRect.minX) * scale + offsetX,
            y: (point.y - worldRect.minY) * scale + offsetY
        )
    }

    private func miniMapToWorld(_ point: CGPoint, size: CGSize, worldRect: CGRect) -> CGPoint {
        let scaleX = (size.width - padding * 2) / worldRect.width
        let scaleY = (size.height - padding * 2) / worldRect.height
        let scale = min(scaleX, scaleY)
        let offsetX = (size.width - worldRect.width * scale) / 2
        let offsetY = (size.height - worldRect.height * scale) / 2
        return CGPoint(
            x: (point.x - offsetX) / scale + worldRect.minX,
            y: (point.y - offsetY) / scale + worldRect.minY
        )
    }

    // MARK: - Drawing: Shapes

    private func drawShapes(in context: inout GraphicsContext, size: CGSize, worldRect: CGRect) {
        let scaleX = (size.width - padding * 2) / worldRect.width
        let scaleY = (size.height - padding * 2) / worldRect.height
        let scale = min(scaleX, scaleY)
        guard scale > 0, scale.isFinite else { return }

        // The minimap is its own viewport over the same render index. A
        // smaller visit budget reaches the density-tile fallback sooner,
        // which a thumbnail this size cannot visually distinguish from
        // exact drawing anyway.
        let viewport = LayoutRect(
            origin: LayoutPoint(x: worldRect.minX, y: worldRect.minY),
            size: LayoutSize(width: worldRect.width, height: worldRect.height)
        )
        guard let plan = viewModel.renderPlan(
            viewport: viewport,
            pixelsPerMicron: Double(scale),
            options: LayoutRenderPlan.Options(visitBudget: 50_000)
        ) else { return }

        for batch in plan.batches {
            guard viewModel.isLayerVisible(batch.layer) else { continue }
            let layerColor = colorForLayer(batch.layer).opacity(0.5)

            for shape in batch.fullShapes {
                let selected = viewModel.selectedShapeIDs.contains(shape.id)
                let fillColor: Color = selected ? .accentColor.opacity(0.6) : layerColor

                switch shape.geometry {
                case .rect(let rect):
                    let r = projectedRect(
                        LayoutRect(origin: rect.origin, size: rect.size),
                        size: size,
                        worldRect: worldRect
                    )
                    context.fill(Path(r), with: .color(fillColor))
                case .path(let layoutPath):
                    guard let first = layoutPath.points.first else { continue }
                    var path = Path()
                    path.move(to: worldToMiniMap(CGPoint(x: first.x, y: first.y), size: size, worldRect: worldRect))
                    for p in layoutPath.points.dropFirst() {
                        path.addLine(to: worldToMiniMap(CGPoint(x: p.x, y: p.y), size: size, worldRect: worldRect))
                    }
                    context.stroke(path, with: .color(fillColor), lineWidth: 1)
                case .polygon(let polygon):
                    guard let first = polygon.points.first else { continue }
                    var path = Path()
                    path.move(to: worldToMiniMap(CGPoint(x: first.x, y: first.y), size: size, worldRect: worldRect))
                    for p in polygon.points.dropFirst() {
                        path.addLine(to: worldToMiniMap(CGPoint(x: p.x, y: p.y), size: size, worldRect: worldRect))
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(fillColor))
                }
            }

            var boxPath = Path()
            for rect in batch.boxRects {
                boxPath.addRect(projectedRect(rect, size: size, worldRect: worldRect))
            }
            if !boxPath.isEmpty {
                context.fill(boxPath, with: .color(layerColor))
            }
        }

        drawDensityAggregates(in: &context, aggregates: plan.aggregates, size: size, worldRect: worldRect)
    }

    /// Density tiles bucketed by layer and quantized level so even a
    /// fully aggregated million-shape document costs a handful of fills.
    private func drawDensityAggregates(
        in context: inout GraphicsContext,
        aggregates: [LayoutRenderPlan.Aggregate],
        size: CGSize,
        worldRect: CGRect
    ) {
        guard !aggregates.isEmpty else { return }
        let levelCount = 4
        var buckets: [DensityBucket: Path] = [:]
        for aggregate in aggregates {
            guard viewModel.isLayerVisible(aggregate.layer) else { continue }
            let level = min(Int(aggregate.density * Double(levelCount)), levelCount - 1)
            buckets[DensityBucket(layer: aggregate.layer, level: level), default: Path()]
                .addRect(projectedRect(aggregate.rect, size: size, worldRect: worldRect))
        }
        for (bucket, path) in buckets {
            let opacity = 0.2 + 0.3 * (Double(bucket.level) + 0.5) / Double(levelCount)
            context.fill(path, with: .color(colorForLayer(bucket.layer).opacity(opacity)))
        }
    }

    private struct DensityBucket: Hashable {
        var layer: LayoutLayerID
        var level: Int
    }

    private func projectedRect(_ rect: LayoutRect, size: CGSize, worldRect: CGRect) -> CGRect {
        let topLeft = worldToMiniMap(CGPoint(x: rect.minX, y: rect.minY), size: size, worldRect: worldRect)
        let bottomRight = worldToMiniMap(CGPoint(x: rect.maxX, y: rect.maxY), size: size, worldRect: worldRect)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    // MARK: - Drawing: Instances

    private func drawInstances(in context: inout GraphicsContext, size: CGSize, worldRect: CGRect) {
        for (inst, bounds) in viewModel.instanceBoundingBoxes() {
            let topLeft = worldToMiniMap(
                CGPoint(x: bounds.origin.x, y: bounds.origin.y), size: size, worldRect: worldRect
            )
            let bottomRight = worldToMiniMap(
                CGPoint(x: bounds.maxX, y: bounds.maxY), size: size, worldRect: worldRect
            )
            let r = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            let selected = viewModel.selectedInstanceID == inst.id
            let fillColor: Color = selected ? .accentColor.opacity(0.6) : .secondary.opacity(0.4)
            context.fill(Path(r), with: .color(fillColor))
        }
    }

    // MARK: - Drawing: Viewport

    private func drawViewport(
        in context: inout GraphicsContext,
        viewport: CGRect,
        size: CGSize,
        worldRect: CGRect
    ) {
        let topLeft = worldToMiniMap(
            CGPoint(x: viewport.minX, y: viewport.minY), size: size, worldRect: worldRect
        )
        let bottomRight = worldToMiniMap(
            CGPoint(x: viewport.maxX, y: viewport.maxY), size: size, worldRect: worldRect
        )
        let vpMinimap = CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        context.fill(Path(vpMinimap), with: .color(.accentColor.opacity(0.1)))
        context.stroke(Path(vpMinimap), with: .color(.accentColor.opacity(0.7)), lineWidth: 1.5)
    }

    // MARK: - Drawing: Empty State

    private func drawEmptyCrosshair(in context: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let armLength: CGFloat = 10

        var horizontal = Path()
        horizontal.move(to: CGPoint(x: cx - armLength, y: cy))
        horizontal.addLine(to: CGPoint(x: cx + armLength, y: cy))

        var vertical = Path()
        vertical.move(to: CGPoint(x: cx, y: cy - armLength))
        vertical.addLine(to: CGPoint(x: cx, y: cy + armLength))

        let color: Color = .primary.opacity(0.3)
        context.stroke(horizontal, with: .color(color), lineWidth: 1)
        context.stroke(vertical, with: .color(color), lineWidth: 1)
    }

    // MARK: - Navigation Gesture

    private var navigationGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                navigateTo(miniMapPoint: value.location)
            }
    }

    private func navigateTo(miniMapPoint: CGPoint) {
        let viewport = currentViewport
        let worldRect = computeWorldRect(viewport: viewport)
        let worldPoint = miniMapToWorld(miniMapPoint, size: miniMapSize, worldRect: worldRect)
        let canvasSize = viewModel.canvasSize
        viewModel.offset = CGPoint(
            x: canvasSize.width / 2 - CGFloat(worldPoint.x) * viewModel.zoom,
            y: canvasSize.height / 2 - CGFloat(worldPoint.y) * viewModel.zoom
        )
    }

    private func colorForLayer(_ layer: LayoutLayerID) -> Color {
        if let def = viewModel.tech.layerDefinition(for: layer) {
            return Color(
                red: def.color.red,
                green: def.color.green,
                blue: def.color.blue,
                opacity: def.color.alpha
            )
        }
        return .gray
    }
}
