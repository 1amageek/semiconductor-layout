import Foundation
import Testing
import LayoutCore
import LayoutIR
import LayoutTech
import LayoutVerify
@testable import LayoutIO

@Suite("Standard path endpoint preservation", .timeLimit(.minutes(1)))
struct PathExtensionRoundTripTests {
    private func library(begin: Int32? = 250, end: Int32? = -100) -> IRLibrary {
        .init(name: "caps", databaseUnitScale: LayoutTechDatabase.standard().units.scale,
              cells: [.init(name: "TOP", elements: [.path(.init(layer: 1, datatype: 0,
                pathType: .customExtension, width: 1_000,
                points: [.init(x: 0, y: 0), .init(x: 2_000, y: 0)],
                beginExtension: begin, endExtension: end))])])
    }

    @Test func checkedImportAndExportRetainAsymmetricSignedValues() throws {
        let converter = IRLayoutConverter()
        let document = try converter.checkedImportLibrary(library(), tech: .standard())
        guard case .path(let path) = document.cells[0].shapes[0].geometry else { Issue.record("Expected path"); return }
        #expect(path.endCap == .custom(begin: 0.25, end: -0.1))
        let result = try converter.exportLibrary(document, tech: .standard())
        guard case .path(let exported) = result.cells[0].elements[0] else { Issue.record("Expected IR path"); return }
        #expect(exported.pathType == .customExtension && exported.beginExtension == 250 && exported.endExtension == -100)
    }

    @Test func gdsBytesRoundTripSignedExtensions() throws {
        let converter = IRLayoutConverter()
        let document = try converter.checkedImportLibrary(library(), tech: .standard())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("path-caps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let file = directory.appendingPathComponent("caps.gds")
        let io = GDSFormatConverter(tech: .standard())
        try io.exportDocument(document, to: file, format: .gds)
        let restored = try io.importDocument(from: file, format: .gds)
        #expect(restored.cells[0].shapes[0].geometry == document.cells[0].shapes[0].geometry)
        let bytes = try Data(contentsOf: file)
        #expect(bytes.count > 0)
    }

    @Test func standardOASISBytesSurviveExportAndElectricalCapture() throws {
        var bytes = Data("%SEMI-OASIS\r\n".utf8)
        bytes.append(contentsOf: [1, 3, 49, 46, 48, 0, 232, 7, 0])
        bytes.append(Data(repeating: 0, count: 12))
        // Inline C; width 1000, begin 2000, end -500, spine (0,0)..(2000,0).
        bytes.append(contentsOf: [14, 1, 67, 22, 251, 1, 0, 244, 3, 15, 160, 31, 233, 7, 0, 1, 160, 31, 0, 0])
        bytes.append(contentsOf: [2, 252, 1])
        bytes.append(Data(repeating: 0, count: 252))
        bytes.append(0)
        let io = MaskDataFormatConverter(tech: .standard())
        let document = try io.importFromData(bytes)
        #expect(document.units.scale.databaseUnitsPerMicrometer == 1000)
        guard case .path(let path) = document.cells[0].shapes[0].geometry else { Issue.record("Expected PATH"); return }
        #expect(path.endCap == .custom(begin: 2, end: -0.5))
        #expect(path.width == 1 && path.points == [.zero, .init(x: 2, y: 0)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oasis-caps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let file = directory.appendingPathComponent("caps.oas")
        try io.exportDocument(document, to: file, format: .oasis)
        let restored = try io.importDocument(from: file, format: .oasis)
        #expect(restored.cells[0].shapes[0].geometry == document.cells[0].shapes[0].geometry)
        let layer = restored.cells[0].shapes[0].layer
        let snapshot = try LayoutConnectivityExtractor().captureConductors(document: restored, tech: .standard(), conductiveLayers: [layer])
        let band = try #require(snapshot.footprints.first?.band)
        #expect(snapshot.footprints.count == 1 && snapshot.components.count == 1)
        #expect(snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer == 2000)
        #expect(band.minX == -4000 && band.maxX == 3000 && band.minY == -1000 && band.maxY == 1000)
    }

    @Test func missingOrIgnoredCustomFieldsFailAdmission() {
        let converter = IRLayoutConverter()
        for input in [library(begin: nil), library(end: nil)] {
            #expect(throws: LayoutIOError.self) { try converter.checkedImportLibrary(input, tech: .standard()) }
        }
        var input = library()
        guard case .path(var path) = input.cells[0].elements[0] else { return }
        path.pathType = .halfWidthExtend
        input.cells[0].elements[0] = .path(path)
        #expect(throws: LayoutIOError.self) { try converter.checkedImportLibrary(input, tech: .standard()) }
    }

    @Test func invalidOrOffGridExportPreservesExistingOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("path-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cleanup failed: \(error)") } }
        let file = directory.appendingPathComponent("caps.gds"), original = Data("existing".utf8)
        let io = GDSFormatConverter(tech: .standard())
        for begin in [Double.infinity, 0.00025, Double(Int32.max) / 1000 + 1] {
            var doc = try IRLayoutConverter().checkedImportLibrary(library(), tech: .standard())
            doc.cells[0].shapes[0].geometry = .path(.init(points: [.zero, .init(x: 2, y: 0)], width: 1,
                                                      endCap: .custom(begin: begin, end: 0)))
            try original.write(to: file)
            #expect(throws: LayoutIOError.self) { try io.exportDocument(doc, to: file, format: .gds) }
            #expect(try Data(contentsOf: file) == original)
        }
    }
}
