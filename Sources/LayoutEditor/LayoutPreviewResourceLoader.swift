import Foundation
import CoreGraphics
import LayoutCore
import LayoutIO
import LayoutTech

public struct LayoutPreviewResourceLoader: Sendable {
    public init() {}

    @MainActor
    public func makeNANDFlashViewModel() throws -> LayoutEditorViewModel {
        let resourceName = "nand_flash_small.gds"
        guard let artifactURL = Bundle.module.url(
            forResource: resourceName,
            withExtension: nil,
            subdirectory: "Resources"
        ) else {
            throw LayoutPreviewResourceError.resourceUnavailable(name: resourceName)
        }

        let technology: LayoutTechDatabase
        do {
            guard let resolved = try LayoutTechSidecarResolver().resolve(for: artifactURL) else {
                throw LayoutPreviewResourceError.technologySidecarUnavailable(name: resourceName)
            }
            technology = resolved
        } catch let error as LayoutPreviewResourceError {
            throw error
        } catch {
            throw LayoutPreviewResourceError.technologyLoadFailed(
                description: error.localizedDescription
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: artifactURL)
        } catch {
            throw LayoutPreviewResourceError.layoutReadFailed(
                description: error.localizedDescription
            )
        }

        let document: LayoutDocument
        do {
            document = try MaskDataFormatConverter(tech: technology).importFromData(data)
        } catch {
            throw LayoutPreviewResourceError.layoutImportFailed(
                description: error.localizedDescription
            )
        }

        let viewModel = LayoutEditorViewModel(document: document, tech: technology)
        viewModel.canvasSize = CGSize(width: 1200, height: 700)
        viewModel.fitAll()
        return viewModel
    }
}
