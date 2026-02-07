import Foundation
import LayoutTech

/// Resolves optional technology sidecar files located next to layout files.
/// Supports KLayout `.lyp`, LEF `.lef`, and IRTechLibrary `.json` formats.
public struct LayoutTechSidecarResolver: Sendable {
    private let converter: TechFormatConverter

    public init(converter: TechFormatConverter = TechFormatConverter()) {
        self.converter = converter
    }

    /// Returns a decoded tech database if a sidecar exists, otherwise nil.
    public func resolve(for layoutURL: URL) throws -> LayoutTechDatabase? {
        let fileManager = FileManager.default
        let candidates = sidecarCandidates(for: layoutURL)

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return try converter.loadTech(from: candidate)
        }

        return nil
    }

    private func sidecarCandidates(for layoutURL: URL) -> [URL] {
        let directory = layoutURL.deletingLastPathComponent()
        let baseName = layoutURL.deletingPathExtension().lastPathComponent
        return [
            // KLayout layer properties
            directory.appendingPathComponent("\(baseName).lyp"),
            directory.appendingPathComponent("layers.lyp"),
            directory.appendingPathComponent("tech.lyp"),
            // LEF technology
            directory.appendingPathComponent("\(baseName).lef"),
            directory.appendingPathComponent("tech.lef"),
            // IRTechLibrary JSON
            directory.appendingPathComponent("\(baseName).tech.json"),
            directory.appendingPathComponent("tech.json"),
        ]
    }
}
