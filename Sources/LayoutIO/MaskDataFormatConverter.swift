import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import GDSII
import OASIS
import CIF
import DXF
import FormatDetector

/// Unified format converter that supports all swift-mask-data formats
/// with automatic format detection.
public struct MaskDataFormatConverter: LayoutFormatConverter, Sendable {
    private let bridge: IRLayoutBridge
    private let tech: LayoutTechDatabase

    public init(tech: LayoutTechDatabase) {
        self.bridge = IRLayoutBridge()
        self.tech = tech
    }

    /// Import from raw data with automatic format detection.
    public func importFromData(_ data: Data) throws -> LayoutDocument {
        let format = FormatDetector.detect(data)
        let irLibrary = try readIRLibrary(from: data, format: format)
        return bridge.importLibrary(irLibrary, tech: tech)
    }

    // MARK: - LayoutFormatConverter

    public func importDocument(from url: URL, format: LayoutFileFormat) throws -> LayoutDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LayoutIOError.fileNotFound(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutIOError.readFailed("Failed to read file: \(error)")
        }

        let detectedFormat = mapFileFormat(format)
        let irLibrary = try readIRLibrary(from: data, format: detectedFormat)
        return bridge.importLibrary(irLibrary, tech: tech)
    }

    public func exportDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws {
        let irLibrary = bridge.exportLibrary(document, tech: tech)
        let data: Data
        do {
            data = try writeIRLibrary(irLibrary, format: format)
        } catch {
            throw LayoutIOError.conversionFailed("Failed to write \(format.rawValue): \(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LayoutIOError.writeFailed("Failed to write file: \(error)")
        }
    }

    public func importTech(from url: URL, format: LayoutFileFormat) throws -> LayoutTechDatabase {
        throw LayoutIOError.unsupportedFormat(format)
    }

    public func exportTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws {
        throw LayoutIOError.unsupportedFormat(format)
    }

    // MARK: - Private

    private func readIRLibrary(from data: Data, format: LayoutFormat) throws -> IRLibrary {
        do {
            switch format {
            case .gdsii:
                return try GDSLibraryReader.read(data)
            case .oasis:
                return try OASISLibraryReader.read(data)
            case .cif:
                return try CIFLibraryReader.read(data)
            case .dxf:
                return try DXFLibraryReader.read(data)
            case .unknown, .lef, .def:
                throw LayoutIOError.conversionFailed("Format \(format) cannot be converted to layout geometry")
            }
        } catch let error as LayoutIOError {
            throw error
        } catch {
            throw LayoutIOError.conversionFailed("Failed to parse \(format): \(error)")
        }
    }

    private func writeIRLibrary(_ library: IRLibrary, format: LayoutFileFormat) throws -> Data {
        switch format {
        case .gds:
            return try GDSLibraryWriter.write(library)
        case .oasis:
            return try OASISLibraryWriter.write(library)
        case .cif:
            return try CIFLibraryWriter.write(library)
        case .dxf:
            return try DXFLibraryWriter.write(library)
        default:
            throw LayoutIOError.unsupportedFormat(format)
        }
    }

    private func mapFileFormat(_ format: LayoutFileFormat) -> LayoutFormat {
        switch format {
        case .gds: return .gdsii
        case .oasis: return .oasis
        case .cif: return .cif
        case .dxf: return .dxf
        case .lef: return .lef
        case .def: return .def
        default: return .unknown
        }
    }
}
