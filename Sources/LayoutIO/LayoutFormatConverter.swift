import Foundation
import LayoutCore
import LayoutTech

public protocol LayoutFormatConverter: Sendable {
    func importDocument(from url: URL, format: LayoutFileFormat) throws -> LayoutDocument
    func exportDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws
    func importTech(from url: URL, format: LayoutFileFormat) throws -> LayoutTechDatabase
    func exportTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws
}
