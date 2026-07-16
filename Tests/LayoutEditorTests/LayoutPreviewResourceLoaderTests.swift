import Testing
@testable import LayoutEditor

@Suite("Layout Preview Resource Loader")
@MainActor
struct LayoutPreviewResourceLoaderTests {
    @Test func loadsPackagedNANDFlashArtifact() throws {
        let viewModel = try LayoutPreviewResourceLoader().makeNANDFlashViewModel()

        #expect(!viewModel.editor.document.cells.isEmpty)
        #expect(viewModel.activeCellID != nil)
    }
}
