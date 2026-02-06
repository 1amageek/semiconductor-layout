import SwiftUI
import LayoutCore
import LayoutTech

public struct LayoutCanvasView: View {
    @Bindable var viewModel: LayoutEditorViewModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                drawShapes(context: &context, size: size)
                drawSelection(context: &context, size: size)
                drawDragPreview(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: proxy.size))
            .background(Color.black.opacity(0.02))
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if viewModel.tool == .rectangle {
                    if dragStart == nil { dragStart = value.startLocation }
                    dragCurrent = value.location
                }
            }
            .onEnded { value in
                let start = dragStart ?? value.startLocation
                let end = value.location
                handleGesture(start: start, end: end, size: size)
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func handleGesture(start: CGPoint, end: CGPoint, size: CGSize) {
        let startLayout = toLayout(start, size: size)
        let endLayout = toLayout(end, size: size)
        let distance = hypot(end.x - start.x, end.y - start.y)

        switch viewModel.tool {
        case .rectangle:
            if distance > 2 {
                viewModel.addRectangle(from: startLayout, to: endLayout)
            }
        case .select:
            viewModel.selectShape(at: endLayout)
        case .via:
            viewModel.addVia(at: endLayout)
        case .label:
            viewModel.addLabel(text: "LABEL", at: endLayout)
        case .pin:
            viewModel.addPin(name: "PIN", at: endLayout, size: LayoutSize(width: 0.2, height: 0.2))
        case .path:
            viewModel.addPath(points: [startLayout, endLayout], width: 0.1)
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let spacing = CGFloat(viewModel.gridSize) * viewModel.zoom
        guard spacing > 2 else { return }
        let width = size.width
        let height = size.height

        var path = Path()
        let startX = (viewModel.offset.width.truncatingRemainder(dividingBy: spacing))
        let startY = (viewModel.offset.height.truncatingRemainder(dividingBy: spacing))

        var x = startX
        while x < width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
            x += spacing
        }

        var y = startY
        while y < height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            y += spacing
        }

        context.stroke(path, with: .color(Color.gray.opacity(0.2)), lineWidth: 0.5)
    }

    private func drawShapes(context: inout GraphicsContext, size: CGSize) {
        for shape in viewModel.documentShapes() {
            let path = pathForShape(shape, size: size)
            let color = colorForLayer(shape.layer)
            switch shape.geometry {
            case .path:
                context.stroke(path, with: .color(color), lineWidth: pathLineWidth(for: shape) * viewModel.zoom)
            default:
                context.fill(path, with: .color(color.opacity(0.6)))
            }
        }
    }

    private func drawSelection(context: inout GraphicsContext, size: CGSize) {
        for shape in viewModel.documentShapes() where viewModel.selectedShapeIDs.contains(shape.id) {
            let path = pathForShape(shape, size: size)
            context.stroke(path, with: .color(Color.yellow), lineWidth: 2)
        }
    }

    private func drawDragPreview(context: inout GraphicsContext, size: CGSize) {
        guard viewModel.tool == .rectangle,
              let start = dragStart,
              let current = dragCurrent else { return }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        let path = Path(rect)
        context.stroke(path, with: .color(Color.blue), lineWidth: 1)
    }

    private func pathForShape(_ shape: LayoutShape, size: CGSize) -> Path {
        switch shape.geometry {
        case .rect(let rect):
            let topLeft = toView(LayoutPoint(x: rect.minX, y: rect.minY), size: size)
            let bottomRight = toView(LayoutPoint(x: rect.maxX, y: rect.maxY), size: size)
            let viewRect = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            return Path(viewRect)
        case .polygon(let polygon):
            var path = Path()
            guard let first = polygon.points.first else { return path }
            path.move(to: toView(first, size: size))
            for point in polygon.points.dropFirst() {
                path.addLine(to: toView(point, size: size))
            }
            path.closeSubpath()
            return path
        case .path(let layoutPath):
            var path = Path()
            guard let first = layoutPath.points.first else { return path }
            path.move(to: toView(first, size: size))
            for point in layoutPath.points.dropFirst() {
                path.addLine(to: toView(point, size: size))
            }
            return path
        }
    }

    private func pathLineWidth(for shape: LayoutShape) -> CGFloat {
        if case .path(let layoutPath) = shape.geometry {
            return CGFloat(layoutPath.width)
        }
        return 1
    }

    private func toLayout(_ point: CGPoint, size: CGSize) -> LayoutPoint {
        let x = (point.x - size.width / 2 - viewModel.offset.width) / viewModel.zoom
        let y = (point.y - size.height / 2 - viewModel.offset.height) / viewModel.zoom
        return LayoutPoint(x: Double(x), y: Double(y))
    }

    private func toView(_ point: LayoutPoint, size: CGSize) -> CGPoint {
        let x = CGFloat(point.x) * viewModel.zoom + size.width / 2 + viewModel.offset.width
        let y = CGFloat(point.y) * viewModel.zoom + size.height / 2 + viewModel.offset.height
        return CGPoint(x: x, y: y)
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
