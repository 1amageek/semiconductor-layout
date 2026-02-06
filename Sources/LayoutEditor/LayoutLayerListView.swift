import SwiftUI
import LayoutTech

public struct LayoutLayerListView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layers")
                .font(.headline)
            List(viewModel.tech.layers, id: \.id) { layer in
                Button {
                    viewModel.activeLayer = layer.id
                } label: {
                    HStack {
                        Circle()
                            .fill(color(for: layer.color))
                            .frame(width: 10, height: 10)
                        Text(layer.displayName)
                        if viewModel.activeLayer == layer.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 200)
        }
        .padding()
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
