import SwiftUI

public struct LayoutToolPaletteView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.headline)
            ForEach([LayoutTool.select, .rectangle, .path, .via, .label, .pin], id: \.self) { tool in
                Button {
                    viewModel.tool = tool
                } label: {
                    HStack {
                        Text(toolLabel(tool))
                        if viewModel.tool == tool {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            Button("Run DRC") {
                viewModel.runDRC()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func toolLabel(_ tool: LayoutTool) -> String {
        switch tool {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .path: return "Path"
        case .via: return "Via"
        case .label: return "Label"
        case .pin: return "Pin"
        }
    }
}
