import Foundation
import LayoutIO

public struct ExternalToolConfiguration: Hashable, Sendable, Codable {
    public var documentImport: [LayoutFileFormat: ExternalToolCommand]
    public var documentExport: [LayoutFileFormat: ExternalToolCommand]
    public var techImport: [LayoutFileFormat: ExternalToolCommand]
    public var techExport: [LayoutFileFormat: ExternalToolCommand]

    public init(
        documentImport: [LayoutFileFormat: ExternalToolCommand] = [:],
        documentExport: [LayoutFileFormat: ExternalToolCommand] = [:],
        techImport: [LayoutFileFormat: ExternalToolCommand] = [:],
        techExport: [LayoutFileFormat: ExternalToolCommand] = [:]
    ) {
        self.documentImport = documentImport
        self.documentExport = documentExport
        self.techImport = techImport
        self.techExport = techExport
    }
}
