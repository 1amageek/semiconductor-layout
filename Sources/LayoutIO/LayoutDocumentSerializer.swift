import Foundation
import LayoutCore
import LayoutTech

public struct LayoutDocumentSerializer: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encodeDocument(_ document: LayoutDocument) throws -> Data {
        do {
            return try encoder.encode(document)
        } catch {
            throw LayoutIOError.writeFailed("Failed to encode document: \(error)")
        }
    }

    public func decodeDocument(_ data: Data) throws -> LayoutDocument {
        do {
            return try decoder.decode(LayoutDocument.self, from: data)
        } catch {
            throw LayoutIOError.readFailed("Failed to decode document: \(error)")
        }
    }

    public func encodeTech(_ tech: LayoutTechDatabase) throws -> Data {
        do {
            return try encoder.encode(tech)
        } catch {
            throw LayoutIOError.writeFailed("Failed to encode tech: \(error)")
        }
    }

    public func decodeTech(_ data: Data) throws -> LayoutTechDatabase {
        do {
            return try decoder.decode(LayoutTechDatabase.self, from: data)
        } catch {
            throw LayoutIOError.readFailed("Failed to decode tech: \(error)")
        }
    }
}
