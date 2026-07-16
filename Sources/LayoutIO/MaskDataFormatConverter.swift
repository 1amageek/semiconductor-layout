import Foundation
import LayoutCore
import LayoutTech
import LayoutIR
import GDSII
import OASIS
import CIF
import DXF
import DEF
import FormatDetector

/// Unified format converter that supports all swift-mask-data formats
/// with automatic format detection.
public struct MaskDataFormatConverter: LayoutFormatConverter, Sendable {
    private let converter: IRLayoutConverter
    private let tech: LayoutTechDatabase

    public init(tech: LayoutTechDatabase) {
        self.converter = IRLayoutConverter()
        self.tech = tech
    }

    /// Import from raw data with automatic format detection.
    public func importFromData(_ data: Data) throws -> LayoutDocument {
        let format = FormatDetector.detect(data)
        if format == .def {
            let document = try readDEFDocument(from: data)
            return try importDEFDocument(document)
        }
        let irLibrary = try readIRLibrary(from: data, format: format)
        return try converter.checkedImportLibrary(irLibrary, tech: tech)
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
        if detectedFormat == .def {
            let document = try readDEFDocument(from: data)
            return try importDEFDocument(document)
        }
        let irLibrary = try readIRLibrary(from: data, format: detectedFormat)
        return try converter.checkedImportLibrary(irLibrary, tech: tech)
    }

    public func exportDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws {
        let exportTech = try effectiveExportTechnology(for: document, format: format)
        let exportedLibrary = try converter.exportLibrary(
            document,
            tech: exportTech,
            includeDEFRouteMetadata: format == .def
        )
        let irLibrary = format == .def
            ? libraryWithTopCellFirst(exportedLibrary, document: document)
            : exportedLibrary
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LayoutIOError.fileNotFound(url.path)
        }
        guard mapFileFormat(format) == .def else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutIOError.readFailed("Failed to read file: \(error)")
        }
        let document = try readDEFDocument(from: data)
        return DEFViaDefinitionTechAugmentor().augmenting(
            tech,
            with: document.viaDefs,
            dbuPerMicron: document.dbuPerMicron
        )
    }

    public func exportTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws {
        throw LayoutIOError.unsupportedFormat(format)
    }

    // MARK: - Private

    private func importDEFDocument(_ document: DEFDocument) throws -> LayoutDocument {
        let importTech = DEFViaDefinitionTechAugmentor().augmenting(
            tech,
            with: document.viaDefs,
            dbuPerMicron: document.dbuPerMicron
        )
        let library = try DEFIRConverter.toIRLibrary(
            document,
            layerNumbers: try defLayerNumberMapping(from: importTech)
        )
        return try converter.checkedImportLibrary(library, tech: importTech)
    }

    private func effectiveExportTechnology(
        for document: LayoutDocument,
        format: LayoutFileFormat
    ) throws -> LayoutTechDatabase {
        guard format == .def else { return tech }
        guard let topCell = topCell(in: document) else { return tech }

        let viaDefs = try DEFViaDefinitionPropertyDecoder().viaDefinitions(from: topCell.properties)
        guard !viaDefs.isEmpty else { return tech }

        return DEFViaDefinitionTechAugmentor().augmenting(
            tech,
            with: viaDefs,
            dbuPerMicron: document.units.scale.databaseUnitsPerMicrometer
        )
    }

    private func topCell(in document: LayoutDocument) -> LayoutCell? {
        if let topCellID = document.topCellID,
           let cell = document.cell(withID: topCellID) {
            return cell
        }
        return document.cells.first
    }

    private func readDEFDocument(from data: Data) throws -> DEFDocument {
        do {
            return try DEFLibraryReader.read(data)
        } catch let error as LayoutIOError {
            throw error
        } catch {
            throw LayoutIOError.conversionFailed("Failed to parse DEF: \(error)")
        }
    }

    private func readIRLibrary(from data: Data, format: LayoutFormat) throws -> IRLibrary {
        do {
            switch format {
            case .gdsii:
                return try GDSLibraryReader.read(data)
            case .oasis:
                return try OASISLibraryReader.read(data)
            case .cif:
                return try CIFLibraryReader.read(data, databaseUnitScale: tech.units.scale)
            case .dxf:
                return try DXFLibraryReader.read(data, databaseUnitScale: tech.units.scale)
            case .def:
                let document = try readDEFDocument(from: data)
                let importTech = DEFViaDefinitionTechAugmentor().augmenting(
                    tech,
                    with: document.viaDefs,
                    dbuPerMicron: document.dbuPerMicron
                )
                return try DEFIRConverter.toIRLibrary(
                    document,
                    layerNumbers: try defLayerNumberMapping(from: importTech)
                )
            case .unknown, .lef:
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
        case .def:
            let document = DEFIRConverter.toDEFDocument(library)
            return try DEFLibraryWriter.write(document)
        default:
            throw LayoutIOError.unsupportedFormat(format)
        }
    }

    private func defLayerNumberMapping(from tech: LayoutTechDatabase) throws -> DEFLayerNumberMapping {
        var layerNumbersByName: [String: Int16] = [:]
        for layer in tech.layers {
            guard layer.gdsLayer > 0, layer.gdsLayer <= Int(Int16.max) else {
                throw LayoutIOError.conversionFailed(
                    "DEF layer '\(layer.id.name)' maps to unsupported GDS layer \(layer.gdsLayer)"
                )
            }
            let layerNumber = Int16(layer.gdsLayer)
            layerNumbersByName[layer.id.name] = layerNumber
            layerNumbersByName[layer.displayName] = layerNumber
        }
        return try DEFLayerNumberMapping(layerNumbersByName: layerNumbersByName)
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

    private func libraryWithTopCellFirst(_ library: IRLibrary, document: LayoutDocument) -> IRLibrary {
        guard let topCellID = document.topCellID,
              let topCellName = document.cell(withID: topCellID)?.name,
              let topIndex = library.cells.firstIndex(where: { $0.name == topCellName }) else {
            return library
        }
        var cells = library.cells
        let topCell = cells.remove(at: topIndex)
        cells.insert(topCell, at: 0)
        return IRLibrary(
            name: library.name,
            databaseUnitScale: library.databaseUnitScale,
            cells: cells,
            metadata: library.metadata,
            createdAt: library.createdAt,
            modifiedAt: library.modifiedAt
        )
    }
}
