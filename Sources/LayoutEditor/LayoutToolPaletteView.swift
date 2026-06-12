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
            ForEach([LayoutTool.select, .rectangle, .path, .route, .via, .label, .pin], id: \.self) { tool in
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
        tool.displayLabel
    }
}
