import SwiftUI

struct LayoutNANDFlashPreview: View {
    private let viewModel: LayoutEditorViewModel?
    private let errorMessage: String?

    @MainActor
    init(loader: LayoutPreviewResourceLoader = LayoutPreviewResourceLoader()) {
        do {
            viewModel = try loader.makeNANDFlashViewModel()
            errorMessage = nil
        } catch {
            viewModel = nil
            errorMessage = error.localizedDescription
        }
    }

    var body: some View {
        if let viewModel {
            LayoutEditorView(viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage ?? "The packaged preview could not be loaded.")
            )
        }
    }
}
