import Foundation
import LayoutCore
import LayoutTech

public struct LayoutIOService: Sendable {
    private let serializer: LayoutDocumentSerializer
    private let converter: LayoutFormatConverter?

    public init(serializer: LayoutDocumentSerializer = LayoutDocumentSerializer(), converter: LayoutFormatConverter? = nil) {
        self.serializer = serializer
        self.converter = converter
    }

    public func saveDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws {
        switch format {
        case .json:
            let data = try serializer.encodeDocument(document)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw LayoutIOError.writeFailed("Failed to write document: \(error)")
            }
        default:
            guard let converter else { throw LayoutIOError.unsupportedFormat(format) }
            try converter.exportDocument(document, to: url, format: format)
        }
    }

    public func loadDocument(from url: URL, format: LayoutFileFormat) throws -> LayoutDocument {
        switch format {
        case .json:
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LayoutIOError.fileNotFound(url.path)
            }
            do {
                let data = try Data(contentsOf: url)
                return try serializer.decodeDocument(data)
            } catch let error as LayoutIOError {
                throw error
            } catch {
                throw LayoutIOError.readFailed("Failed to read document: \(error)")
            }
        default:
            guard let converter else { throw LayoutIOError.unsupportedFormat(format) }
            return try converter.importDocument(from: url, format: format)
        }
    }

    public func saveTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws {
        switch format {
        case .json:
            let data = try serializer.encodeTech(tech)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw LayoutIOError.writeFailed("Failed to write tech: \(error)")
            }
        default:
            guard let converter else { throw LayoutIOError.unsupportedFormat(format) }
            try converter.exportTech(tech, to: url, format: format)
        }
    }

    public func loadTech(from url: URL, format: LayoutFileFormat) throws -> LayoutTechDatabase {
        switch format {
        case .json:
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LayoutIOError.fileNotFound(url.path)
            }
            do {
                let data = try Data(contentsOf: url)
                return try serializer.decodeTech(data)
            } catch let error as LayoutIOError {
                throw error
            } catch {
                throw LayoutIOError.readFailed("Failed to read tech: \(error)")
            }
        default:
            guard let converter else { throw LayoutIOError.unsupportedFormat(format) }
            return try converter.importTech(from: url, format: format)
        }
    }
}
