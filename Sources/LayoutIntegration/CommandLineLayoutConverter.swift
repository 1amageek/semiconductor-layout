import Foundation
import LayoutCore
import LayoutTech
import LayoutIO

public struct CommandLineLayoutConverter: LayoutFormatConverter {
    private let configuration: ExternalToolConfiguration
    private let serializer: LayoutDocumentSerializer
    private let nativeConverter: MaskDataFormatConverter?

    /// Formats supported natively via swift-mask-data without external tools.
    private static let nativeFormats: Set<LayoutFileFormat> = [.gds, .oasis, .cif, .dxf]

    public init(
        configuration: ExternalToolConfiguration,
        serializer: LayoutDocumentSerializer = LayoutDocumentSerializer(),
        tech: LayoutTechDatabase? = nil
    ) {
        self.configuration = configuration
        self.serializer = serializer
        self.nativeConverter = tech.map { MaskDataFormatConverter(tech: $0) }
    }

    public func importDocument(from url: URL, format: LayoutFileFormat) throws -> LayoutDocument {
        if format == .json {
            let data = try Data(contentsOf: url)
            return try serializer.decodeDocument(data)
        }
        // Prefer native conversion for mask data formats
        if let native = nativeConverter, Self.nativeFormats.contains(format) {
            return try native.importDocument(from: url, format: format)
        }
        guard let command = configuration.documentImport[format] else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let jsonURL = tempURL(ext: "json")
        try run(command: command, input: url, output: jsonURL)
        let data = try Data(contentsOf: jsonURL)
        return try serializer.decodeDocument(data)
    }

    public func exportDocument(_ document: LayoutDocument, to url: URL, format: LayoutFileFormat) throws {
        if format == .json {
            let data = try serializer.encodeDocument(document)
            try data.write(to: url, options: .atomic)
            return
        }
        // Prefer native conversion for mask data formats
        if let native = nativeConverter, Self.nativeFormats.contains(format) {
            try native.exportDocument(document, to: url, format: format)
            return
        }
        guard let command = configuration.documentExport[format] else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let jsonURL = tempURL(ext: "json")
        let data = try serializer.encodeDocument(document)
        try data.write(to: jsonURL, options: .atomic)
        try run(command: command, input: jsonURL, output: url)
    }

    public func importTech(from url: URL, format: LayoutFileFormat) throws -> LayoutTechDatabase {
        if format == .json {
            let data = try Data(contentsOf: url)
            return try serializer.decodeTech(data)
        }
        guard let command = configuration.techImport[format] else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let jsonURL = tempURL(ext: "json")
        try run(command: command, input: url, output: jsonURL)
        let data = try Data(contentsOf: jsonURL)
        return try serializer.decodeTech(data)
    }

    public func exportTech(_ tech: LayoutTechDatabase, to url: URL, format: LayoutFileFormat) throws {
        if format == .json {
            let data = try serializer.encodeTech(tech)
            try data.write(to: url, options: .atomic)
            return
        }
        guard let command = configuration.techExport[format] else {
            throw LayoutIOError.unsupportedFormat(format)
        }
        let jsonURL = tempURL(ext: "json")
        let data = try serializer.encodeTech(tech)
        try data.write(to: jsonURL, options: .atomic)
        try run(command: command, input: jsonURL, output: url)
    }

    private func run(command: ExternalToolCommand, input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments.map {
            $0.replacingOccurrences(of: "{input}", with: input.path)
                .replacingOccurrences(of: "{output}", with: output.path)
        }

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            throw LayoutIOError.conversionFailed("Failed to run command: \(error)")
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: data, encoding: .utf8) ?? ""
            throw LayoutIOError.conversionFailed("Command failed: \(outputText)")
        }
    }

    private func tempURL(ext: String) -> URL {
        let filename = "layout_\(UUID().uuidString).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}
