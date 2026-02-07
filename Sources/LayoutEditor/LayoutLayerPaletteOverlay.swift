import SwiftUI
import LayoutTech

/// Floating layer palette overlay for the layout canvas.
///
/// Displays layers as a compact list with visibility toggles, pattern swatches,
/// and active layer selection. Positioned at the top-leading corner of the canvas.
public struct LayoutLayerPaletteOverlay: View {
    @Bindable var viewModel: LayoutEditorViewModel
    @State private var isExpanded: Bool = true

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                Divider()
                layerList
            }
        }
        .frame(width: 170)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Layers")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var layerList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.tech.layers, id: \.id) { layer in
                layerRow(layer)
                if layer.id != viewModel.tech.layers.last?.id {
                    Divider().padding(.leading, 30)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func layerRow(_ layer: LayoutLayerDefinition) -> some View {
        let isActive = viewModel.activeLayer == layer.id
        let isVisible = viewModel.isLayerVisible(layer.id)

        return HStack(spacing: 6) {
            // Visibility toggle
            Button {
                viewModel.toggleLayerVisibility(layer.id)
            } label: {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(isVisible ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            // Layer swatch + name (tap to select active layer)
            Button {
                viewModel.activeLayer = layer.id
            } label: {
                HStack(spacing: 6) {
                    layerSwatch(layer)
                    Text(layer.displayName)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .opacity(isVisible ? 1 : 0.4)
                    Spacer()
                    if isActive {
                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.accentColor.opacity(0.1) : Color.clear,
            in: Rectangle()
        )
        .opacity(isVisible ? 1 : 0.5)
    }

    private func layerSwatch(_ layer: LayoutLayerDefinition) -> some View {
        let baseColor = color(for: layer.color)
        let pattern = layer.fillPattern
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let fillPath = Path(rect)

            context.fill(fillPath, with: .color(baseColor.opacity(0.5)))

            if pattern != .solid {
                context.drawLayer { ctx in
                    ctx.clip(to: fillPath)
                    var lp = Path()
                    let sp: CGFloat = 5
                    let h = size.height
                    let w = size.width

                    if pattern == .forwardDiagonal || pattern == .crosshatch {
                        var x = -h
                        while x <= w { lp.move(to: .init(x: x, y: h)); lp.addLine(to: .init(x: x + h, y: 0)); x += sp }
                    }
                    if pattern == .backwardDiagonal || pattern == .crosshatch {
                        var x = -h
                        while x <= w { lp.move(to: .init(x: x, y: 0)); lp.addLine(to: .init(x: x + h, y: h)); x += sp }
                    }
                    if pattern == .horizontal || pattern == .grid {
                        var y = sp
                        while y < h { lp.move(to: .init(x: 0, y: y)); lp.addLine(to: .init(x: w, y: y)); y += sp }
                    }
                    if pattern == .vertical || pattern == .grid {
                        var x = sp
                        while x < w { lp.move(to: .init(x: x, y: 0)); lp.addLine(to: .init(x: x, y: h)); x += sp }
                    }

                    if pattern == .dots {
                        let r: CGFloat = 1.2
                        var y = sp / 2
                        while y <= h {
                            var x = sp / 2
                            while x <= w {
                                lp.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                                x += sp
                            }
                            y += sp
                        }
                        ctx.fill(lp, with: .color(baseColor))
                    } else {
                        ctx.stroke(lp, with: .color(baseColor), lineWidth: 1)
                    }
                }
            }

            context.stroke(
                Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                with: .color(baseColor),
                lineWidth: 1
            )
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func color(for layoutColor: LayoutColor) -> Color {
        Color(
            red: layoutColor.red,
            green: layoutColor.green,
            blue: layoutColor.blue,
            opacity: layoutColor.alpha
        )
    }
}
