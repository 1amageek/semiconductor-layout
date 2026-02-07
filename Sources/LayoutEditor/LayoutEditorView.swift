import SwiftUI

public struct LayoutEditorView: View {
    @Bindable var viewModel: LayoutEditorViewModel

    public init(viewModel: LayoutEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            LayoutCanvasView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 8) {
                        LayoutToolPaletteOverlay(viewModel: viewModel)
                        LayoutLayerPaletteOverlay(viewModel: viewModel)
                    }
                    .padding(12)
                }
                .overlay(alignment: .top) {
                    LayoutToolOptionsOverlay(viewModel: viewModel)
                        .padding(.top, 12)
                }
                .overlay(alignment: .bottomLeading) {
                    LayoutZoomControlView(viewModel: viewModel)
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    LayoutMiniMapView(viewModel: viewModel)
                        .padding(12)
                }
                .layoutPriority(1)

            if !viewModel.violations.isEmpty {
                LayoutDiagnosticsBar(violations: viewModel.violations)
            }
        }
    }
}

#Preview("Layout Editor") {
    LayoutEditorView(viewModel: LayoutEditorViewModel())
        .frame(width: 1200, height: 700)
}
