import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import GDSII

/// GDSII format converter implementing LayoutFormatConverter protocol.
public struct GDSFormatConverter: LayoutFormatConverter {
    private let bridge: IRLayoutBridge
    private let tech: LayoutTechDatabase

    public init(tech: LayoutTechDatabase) {
        self.bridge = IRLayoutBridge()
        self.tech = tech
    }

    public func importDocument(from url: URL, format: LayoutFileFormat) throws -> LayoutDocument {
        guard format == .gds else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LayoutIOError.fileNotFound(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutIOError.readFailed("Failed to read GDS file: \(error)")
        }
        let irLibrary: IRLibrary
        do {
            irLibrary = try GDSLibraryReader.read(data)
        } catch {
            throw LayoutIOError.conversionFailed("Failed to parse GDS: \(error)")
        }
        return try bridge.checkedImportLibrary(irLibrary, tech: tech)
    }

    public func exportDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws {
        guard format == .gds else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let irLibrary = try bridge.exportLibrary(document, tech: tech)
        let data: Data
        do {
            data = try GDSLibraryWriter.write(irLibrary)
        } catch {
            throw LayoutIOError.conversionFailed("Failed to write GDS: \(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LayoutIOError.writeFailed("Failed to write GDS file: \(error)")
        }
    }

    public func importTech(from url: URL, format: LayoutFileFormat) throws -> LayoutTechDatabase {
        throw LayoutIOError.unsupportedFormat(format)
    }

    public func exportTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws {
        throw LayoutIOError.unsupportedFormat(format)
    }
}
