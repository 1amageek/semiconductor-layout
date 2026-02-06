import SwiftUI

public struct LayoutEditorView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                LayoutToolPaletteView(viewModel: viewModel)
                if let error = viewModel.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                LayoutLayerListView(viewModel: viewModel)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            LayoutCanvasView(viewModel: viewModel)
                .frame(minWidth: 600)

            LayoutViolationListView(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        }
    }
}

#Preview("Layout Editor") {
    LayoutEditorView(viewModel: LayoutEditorViewModel())
        .frame(width: 1200, height: 700)
}
