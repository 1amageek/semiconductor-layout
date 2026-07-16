import Foundation
import LayoutTech
import TechIR
import LEF

/// Unified loader for technology files. Supports `.lyp`, `.lef`, and `.json` (IRTechLibrary).
public struct TechFormatConverter: Sendable {

    private let lypParser: KLayoutLypTechParser
    private let bridge: IRTechLayoutBridge

    public init(
        lypParser: KLayoutLypTechParser = KLayoutLypTechParser(),
        bridge: IRTechLayoutBridge = IRTechLayoutBridge()
    ) {
        self.lypParser = lypParser
        self.bridge = bridge
    }

    /// Loads a technology file from `url` and returns a `LayoutTechDatabase`.
    public func loadTech(from url: URL) throws -> LayoutTechDatabase {
        let irLib = try loadIRTech(from: url)
        return try bridge.importTechLibrary(irLib)
    }

    /// Loads a technology file from `url` and returns the intermediate `IRTechLibrary`.
    public func loadIRTech(from url: URL) throws -> IRTechLibrary {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutIOError.readFailed("Failed to read '\(url.lastPathComponent)': \(error)")
        }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "lyp":
            return try lypParser.parseToIRTech(data: data)

        case "lef":
            let doc = try LEFLibraryReader.read(data)
            return LEFTechIRConverter.toIRTechLibrary(doc)

        case "json":
            do {
                return try JSONDecoder().decode(IRTechLibrary.self, from: data)
            } catch {
                throw LayoutIOError.readFailed("Failed to decode IRTechLibrary JSON: \(error)")
            }

        default:
            throw LayoutIOError.readFailed("Unsupported tech file format: .\(ext)")
        }
    }

    /// Saves an `IRTechLibrary` as JSON to the given URL.
    public func saveTechAsJSON(_ lib: IRTechLibrary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(lib)
        } catch {
            throw LayoutIOError.writeFailed("Failed to encode IRTechLibrary: \(error)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LayoutIOError.writeFailed("Failed to write '\(url.lastPathComponent)': \(error)")
        }
    }
}
