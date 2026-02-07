import SwiftUI

/// Floating vertical tool palette for the layout canvas.
///
/// Displays layout tools as a compact icon strip along the leading edge.
/// The active tool is highlighted with accent color.
struct LayoutToolPaletteOverlay: View {
    @Bindable var viewModel: LayoutEditorViewModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(LayoutTool.allCases, id: \.self) { tool in
                toolButton(tool)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func toolButton(_ tool: LayoutTool) -> some View {
        Button {
            viewModel.tool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(viewModel.tool == tool ? Color.accentColor : .primary)
                .background(
                    viewModel.tool == tool
                        ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                        : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help("\(tool.displayLabel)\(shortcutLabel(tool))")
    }

    private func shortcutLabel(_ tool: LayoutTool) -> String {
        guard let key = tool.shortcutKey else { return "" }
        return " (\(key.uppercased()))"
    }
}
