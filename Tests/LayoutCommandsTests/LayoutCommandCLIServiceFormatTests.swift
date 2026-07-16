import CircuiteFoundation
import Foundation
import LayoutCommands
import LayoutCore
import LayoutIO
import LayoutTech
import Testing

@Suite("Layout command CLI service standard formats", .timeLimit(.minutes(1)))
struct LayoutCommandCLIServiceFormatTests {
    @Test("CLI service converts canonical JSON to GDS and reports artifact evidence")
    func convertsJSONToGDS() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        let service = LayoutCommandCLIService()
        let result = try Self.convertJSONToGDS(fixture: fixture, service: service)

        Self.expectCanonicalGDSConversion(result, fixture: fixture)
        try Self.expectConversionManifest(result, fixture: fixture)
    }

    @Test("CLI service inspects GDS through the native mask-data converter")
    func inspectsGDS() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }
        let service = LayoutCommandCLIService()
        _ = try Self.convertJSONToGDSWithoutArtifacts(fixture: fixture, service: service)
        let result = try Self.inspectGDS(fixture: fixture, service: service)

        try Self.expectGDSInspection(result, fixture: fixture)
        try Self.expectInspectionManifest(result, fixture: fixture)
    }

    @Test("CLI service folds failed inspection verification into top-level status and exit code")
    func failedInspectionReturnsFailedStatusAndExitCode() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }
        try LayoutDocumentSerializer().encodeTech(Self.strictM1Tech()).write(to: fixture.techURL, options: .atomic)

        let response = try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: [
                "--inspect-document",
                "--input", fixture.documentURL.path,
                "--input-format", "json",
                "--tech", fixture.techURL.path,
                "--result", fixture.inspectionResultURL.path,
                "--artifact-manifest", fixture.inspectionManifestURL.path,
                "--json",
            ])
        )
        let inspection = try Self.decodeJSON(LayoutDocumentInspectionResult.self, from: response.output)

        #expect(response.exitCode == 1)
        #expect(inspection.status == "failed")
        #expect(inspection.verification?.status == "failed")
        #expect((inspection.verification?.drc.errorCount ?? 0) > 0)
        #expect((inspection.verification?.drc.diagnosticCount ?? 0) > 0)
        #expect(inspection.verification?.drc.diagnostics.contains {
            $0.code == "drc.geometry_operation_failed" && $0.severity == .error
        } == true)
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionManifestURL.path))
    }

    @Test("CLI service converts and inspects DEF component placement")
    func convertsAndInspectsDEFPlacement() throws {
        let fixture = try Self.makePlacementFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        let service = LayoutCommandCLIService()
        let conversion = try Self.convertPlacementJSONToDEF(fixture: fixture, service: service)
        Self.expectPlacementDEFConversion(conversion)
        let defText = try String(contentsOf: fixture.defURL, encoding: .utf8)
        #expect(defText.contains("- u1 INV + PLACED ( 1250 2500 ) FN"))

        let inspection = try Self.inspectPlacementDEF(fixture: fixture, service: service)
        Self.expectPlacementDEFInspection(inspection, fixture: fixture)
    }

    @Test("CLI service inspects DEF routed nets as developer-visible layout state")
    func inspectsDEFRoutedNets() throws {
        let fixture = try Self.makeRoutingFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        let output = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
            "--inspect-document",
            "--input",
            fixture.defURL.path,
            "--input-format",
            "def",
            "--tech",
            fixture.techURL.path,
            "--result",
            fixture.inspectionResultURL.path,
            "--artifact-manifest",
            fixture.inspectionManifestURL.path,
            "--json",
        ]))
        let inspection = try JSONDecoder().decode(
            LayoutDocumentInspectionResult.self,
            from: Data(output.utf8)
        )

        #expect(inspection.status == "passed")
        #expect(inspection.inputArtifact.format == .def)
        #expect(inspection.summary.netCount == 2)
        #expect(inspection.summary.shapeCount == 4)
        #expect(inspection.summary.viaCount == 2)
        #expect(inspection.summary.layerUsage.contains {
            $0.layer == LayoutLayerID(name: "M1", purpose: "drawing") && $0.elementCount == 2
        })
        #expect(inspection.summary.layerUsage.contains {
            $0.layer == LayoutLayerID(name: "M2", purpose: "drawing") && $0.elementCount == 2
        })
        #expect(inspection.summary.layerUsage.contains {
            $0.layer == LayoutLayerID(name: "VIA1", purpose: "cut") && $0.elementCount == 2
        })
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionManifestURL.path))
    }

    @Test("CLI service uses DEF VIAS as effective technology")
    func usesDEFViasAsEffectiveTechnology() throws {
        let fixture = try Self.makeDEFViaDefinitionFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        let output = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
            "--inspect-document",
            "--input",
            fixture.defURL.path,
            "--input-format",
            "def",
            "--tech",
            fixture.techURL.path,
            "--result",
            fixture.inspectionResultURL.path,
            "--artifact-manifest",
            fixture.inspectionManifestURL.path,
            "--json",
        ]))
        let inspection = try JSONDecoder().decode(
            LayoutDocumentInspectionResult.self,
            from: Data(output.utf8)
        )

        #expect(inspection.status == "passed")
        #expect(inspection.summary.viaCount == 1)
        #expect(inspection.summary.layerUsage.contains {
            $0.layer == LayoutLayerID(name: "DEFVIA", purpose: "cut") && $0.elementCount == 1
        })
        #expect(inspection.verification != nil)
        let violations = inspection.verification?.drc.violations ?? []
        #expect(!violations.contains { $0.message.contains("unknown definition 'DEFVIA'") })
    }

    @Test("CLI service requires technology for standard mask formats")
    func requiresTechnologyForMaskFormats() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        #expect(throws: LayoutCommandError.missingRequiredArgument("--tech")) {
            _ = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
                "--convert-document",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--output",
                fixture.gdsURL.path,
                "--output-format",
                "gds",
            ]))
        }
    }

    @Test("CLI service marks JSON inspection without technology as unverified")
    func jsonInspectionWithoutTechnologyIsUnverified() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        let response = try LayoutCommandCLIService().runWithExitStatus(
            options: LayoutCommandCLIOptions(arguments: [
                "--inspect-document",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--result",
                fixture.inspectionResultURL.path,
                "--artifact-manifest",
                fixture.inspectionManifestURL.path,
                "--json",
            ])
        )
        let inspection = try Self.decodeJSON(LayoutDocumentInspectionResult.self, from: response.output)

        #expect(response.exitCode == 1)
        #expect(inspection.status == "unverified")
        #expect(inspection.verification == nil)
        #expect(inspection.summary.shapeCount > 0)
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionManifestURL.path))
    }

    @Test("CLI service rejects conversion result path colliding with output")
    func rejectsConversionResultPathCollidingWithOutput() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        #expect(throws: LayoutCommandError.conflictingArtifactPath("output and result", fixture.gdsURL.path)) {
            _ = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
                "--convert-document",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--output",
                fixture.gdsURL.path,
                "--output-format",
                "gds",
                "--tech",
                fixture.techURL.path,
                "--result",
                fixture.gdsURL.path,
            ]))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.gdsURL.path))
    }

    @Test("CLI service rejects inspection result path colliding with input")
    func rejectsInspectionResultPathCollidingWithInput() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }
        let originalInput = try Data(contentsOf: fixture.documentURL)

        #expect(throws: LayoutCommandError.conflictingArtifactPath("input and result", fixture.documentURL.path)) {
            _ = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
                "--inspect-document",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--result",
                fixture.documentURL.path,
            ]))
        }
        let currentInput = try Data(contentsOf: fixture.documentURL)
        #expect(currentInput == originalInput)
    }

    @Test("CLI service rejects result and manifest path collision")
    func rejectsResultAndManifestPathCollision() throws {
        let fixture = try Self.makeFixtureDirectory()
        defer { Self.removeTemporaryItem(fixture.directory) }

        #expect(throws: LayoutCommandError.conflictingArtifactPath(
            "result and artifact-manifest",
            fixture.inspectionResultURL.path
        )) {
            _ = try LayoutCommandCLIService().run(options: LayoutCommandCLIOptions(arguments: [
                "--inspect-document",
                "--input",
                fixture.documentURL.path,
                "--input-format",
                "json",
                "--result",
                fixture.inspectionResultURL.path,
                "--artifact-manifest",
                fixture.inspectionResultURL.path,
            ]))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
    }

    private static func convertJSONToGDS(
        fixture: Fixture,
        service: LayoutCommandCLIService
    ) throws -> LayoutDocumentConversionResult {
        let output = try service.run(options: LayoutCommandCLIOptions(arguments: [
            "--convert-document",
            "--input", fixture.documentURL.path,
            "--input-format", "json",
            "--output", fixture.gdsURL.path,
            "--output-format", "gds",
            "--tech", fixture.techURL.path,
            "--result", fixture.conversionResultURL.path,
            "--artifact-manifest", fixture.conversionManifestURL.path,
            "--json",
        ]))
        return try decodeJSON(LayoutDocumentConversionResult.self, from: output)
    }

    private static func convertJSONToGDSWithoutArtifacts(
        fixture: Fixture,
        service: LayoutCommandCLIService
    ) throws -> LayoutDocumentConversionResult {
        let output = try service.run(options: LayoutCommandCLIOptions(arguments: [
            "--convert-document",
            "--input", fixture.documentURL.path,
            "--input-format", "json",
            "--output", fixture.gdsURL.path,
            "--output-format", "gds",
            "--tech", fixture.techURL.path,
            "--json",
        ]))
        return try decodeJSON(LayoutDocumentConversionResult.self, from: output)
    }

    private static func inspectGDS(
        fixture: Fixture,
        service: LayoutCommandCLIService
    ) throws -> LayoutDocumentInspectionResult {
        let output = try service.run(options: LayoutCommandCLIOptions(arguments: [
            "--inspect-document",
            "--input", fixture.gdsURL.path,
            "--input-format", "gds",
            "--tech", fixture.techURL.path,
            "--result", fixture.inspectionResultURL.path,
            "--artifact-manifest", fixture.inspectionManifestURL.path,
            "--json",
        ]))
        return try decodeJSON(LayoutDocumentInspectionResult.self, from: output)
    }

    private static func convertPlacementJSONToDEF(
        fixture: PlacementFixture,
        service: LayoutCommandCLIService
    ) throws -> LayoutDocumentConversionResult {
        let output = try service.run(options: LayoutCommandCLIOptions(arguments: [
            "--convert-document",
            "--input", fixture.documentURL.path,
            "--input-format", "json",
            "--output", fixture.defURL.path,
            "--output-format", "def",
            "--tech", fixture.techURL.path,
            "--result", fixture.conversionResultURL.path,
            "--artifact-manifest", fixture.conversionManifestURL.path,
            "--json",
        ]))
        return try decodeJSON(LayoutDocumentConversionResult.self, from: output)
    }

    private static func inspectPlacementDEF(
        fixture: PlacementFixture,
        service: LayoutCommandCLIService
    ) throws -> LayoutDocumentInspectionResult {
        let output = try service.run(options: LayoutCommandCLIOptions(arguments: [
            "--inspect-document",
            "--input", fixture.defURL.path,
            "--input-format", "def",
            "--tech", fixture.techURL.path,
            "--result", fixture.inspectionResultURL.path,
            "--artifact-manifest", fixture.inspectionManifestURL.path,
            "--json",
        ]))
        return try decodeJSON(LayoutDocumentInspectionResult.self, from: output)
    }

    private static func expectCanonicalGDSConversion(
        _ result: LayoutDocumentConversionResult,
        fixture: Fixture
    ) {
        #expect(result.status == "passed")
        #expect(result.outputArtifact.format == .gdsii)
        #expect(result.outputArtifact.byteCount > 0)
        #expect(result.outputArtifact.digest.hexadecimalValue.count == 64)
        #expect(result.inputArtifact.digest.hexadecimalValue.count == 64)
        #expect(result.outputArtifact.path == fixture.gdsURL.path)
        #expect(result.summary.cellCount == 1)
        #expect(result.summary.shapeCount == 3)
        #expect(FileManager.default.fileExists(atPath: fixture.gdsURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.conversionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.conversionManifestURL.path))
    }

    private static func expectConversionManifest(
        _ result: LayoutDocumentConversionResult,
        fixture: Fixture
    ) throws {
        let manifest = try decodeFile(EvidenceManifest.self, from: fixture.conversionManifestURL)
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "input-layout-document"
                && $0 == result.inputArtifact
        })
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "output-layout-document"
                && $0 == result.outputArtifact
        })
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "technology-profile" && $0.path == fixture.techURL.path
        })
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "layout-conversion-result" && $0.path == fixture.conversionResultURL.path
        })
    }

    private static func expectGDSInspection(
        _ result: LayoutDocumentInspectionResult,
        fixture: Fixture
    ) throws {
        #expect(result.inputArtifact.format == .gdsii)
        #expect(result.inputArtifact.digest.hexadecimalValue.count == 64)
        #expect(result.inputArtifact.byteCount > 0)
        #expect(result.summary.cellCount == 1)
        #expect(result.summary.shapeCount == 3)
        #expect(result.summary.layerUsage.contains {
            $0.layer == LayoutLayerID(name: "M1", purpose: "drawing") && $0.elementCount == 3
        })
        let verification = try #require(result.verification)
        #expect(result.status == verification.status)
        #expect(verification.status == "failed")
        #expect(verification.topCellID == result.summary.topCellID)
        #expect(verification.drc.violationCount == verification.drc.violations.count)
        #expect(verification.drc.diagnosticCount == verification.drc.diagnostics.count)
        #expect(verification.drc.diagnostics.contains { $0.severity == .error })
        #expect(verification.connectivity.extractedNetCount >= 0)
        #expect(verification.connectivity.openCount >= 0)
        #expect(verification.connectivity.shortCount >= 0)
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionManifestURL.path))
    }

    private static func expectInspectionManifest(
        _ result: LayoutDocumentInspectionResult,
        fixture: Fixture
    ) throws {
        let manifest = try decodeFile(EvidenceManifest.self, from: fixture.inspectionManifestURL)
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "input-layout-document"
                && $0 == result.inputArtifact
        })
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "technology-profile" && $0.path == fixture.techURL.path
        })
        #expect(manifest.artifacts.contains {
            $0.locator.role.rawValue == "layout-inspection-result" && $0.path == fixture.inspectionResultURL.path
        })
    }

    private static func expectPlacementDEFConversion(_ conversion: LayoutDocumentConversionResult) {
        #expect(conversion.status == "passed")
        #expect(conversion.outputArtifact.format == .def)
        #expect(conversion.outputArtifact.byteCount > 0)
        #expect(conversion.summary.cellCount == 2)
        #expect(conversion.summary.instanceCount == 1)
    }

    private static func expectPlacementDEFInspection(
        _ inspection: LayoutDocumentInspectionResult,
        fixture: PlacementFixture
    ) {
        #expect(inspection.status == "passed")
        #expect(inspection.inputArtifact.format == .def)
        #expect(inspection.summary.cellCount == 2)
        #expect(inspection.summary.instanceCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionResultURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.inspectionManifestURL.path))
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(output.utf8))
    }

    private static func decodeFile<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private struct Fixture {
        let directory: URL
        let documentURL: URL
        let techURL: URL
        let gdsURL: URL
        let conversionResultURL: URL
        let conversionManifestURL: URL
        let inspectionResultURL: URL
        let inspectionManifestURL: URL
    }

    private struct PlacementFixture {
        let directory: URL
        let documentURL: URL
        let techURL: URL
        let defURL: URL
        let conversionResultURL: URL
        let conversionManifestURL: URL
        let inspectionResultURL: URL
        let inspectionManifestURL: URL
    }

    private struct RoutingFixture {
        let directory: URL
        let defURL: URL
        let techURL: URL
        let inspectionResultURL: URL
        let inspectionManifestURL: URL
    }

    private static func makeFixtureDirectory() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-cli-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let documentURL = directory.appendingPathComponent("layout.json")
        let techURL = directory.appendingPathComponent("tech.json")
        let gdsURL = directory.appendingPathComponent("layout.gds")
        let conversionResultURL = directory.appendingPathComponent("reports/convert-result.json")
        let conversionManifestURL = directory.appendingPathComponent("reports/convert-manifest.json")
        let inspectionResultURL = directory.appendingPathComponent("reports/inspect-result.json")
        let inspectionManifestURL = directory.appendingPathComponent("reports/inspect-manifest.json")
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(simpleDocument()).write(to: documentURL, options: .atomic)
        try serializer.encodeTech(LayoutTechDatabase.standard()).write(to: techURL, options: .atomic)
        return Fixture(
            directory: directory,
            documentURL: documentURL,
            techURL: techURL,
            gdsURL: gdsURL,
            conversionResultURL: conversionResultURL,
            conversionManifestURL: conversionManifestURL,
            inspectionResultURL: inspectionResultURL,
            inspectionManifestURL: inspectionManifestURL
        )
    }

    private static func makePlacementFixtureDirectory() throws -> PlacementFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-cli-def-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let documentURL = directory.appendingPathComponent("placement.json")
        let techURL = directory.appendingPathComponent("tech.json")
        let defURL = directory.appendingPathComponent("placement.def")
        let conversionResultURL = directory.appendingPathComponent("reports/convert-result.json")
        let conversionManifestURL = directory.appendingPathComponent("reports/convert-manifest.json")
        let inspectionResultURL = directory.appendingPathComponent("reports/inspect-result.json")
        let inspectionManifestURL = directory.appendingPathComponent("reports/inspect-manifest.json")
        let serializer = LayoutDocumentSerializer()
        try serializer.encodeDocument(placementDocument()).write(to: documentURL, options: .atomic)
        try serializer.encodeTech(LayoutTechDatabase.standard()).write(to: techURL, options: .atomic)
        return PlacementFixture(
            directory: directory,
            documentURL: documentURL,
            techURL: techURL,
            defURL: defURL,
            conversionResultURL: conversionResultURL,
            conversionManifestURL: conversionManifestURL,
            inspectionResultURL: inspectionResultURL,
            inspectionManifestURL: inspectionManifestURL
        )
    }

    private static func makeRoutingFixtureDirectory() throws -> RoutingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-cli-def-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defURL = directory.appendingPathComponent("routing.def")
        let techURL = directory.appendingPathComponent("tech.json")
        let inspectionResultURL = directory.appendingPathComponent("reports/inspect-result.json")
        let inspectionManifestURL = directory.appendingPathComponent("reports/inspect-manifest.json")
        try routedDEF.write(to: defURL, atomically: true, encoding: .utf8)
        try LayoutDocumentSerializer().encodeTech(LayoutTechDatabase.standard()).write(to: techURL, options: .atomic)
        return RoutingFixture(
            directory: directory,
            defURL: defURL,
            techURL: techURL,
            inspectionResultURL: inspectionResultURL,
            inspectionManifestURL: inspectionManifestURL
        )
    }

    private static func makeDEFViaDefinitionFixtureDirectory() throws -> RoutingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-cli-def-via-definition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defURL = directory.appendingPathComponent("routing.def")
        let techURL = directory.appendingPathComponent("tech.json")
        let inspectionResultURL = directory.appendingPathComponent("reports/inspect-result.json")
        let inspectionManifestURL = directory.appendingPathComponent("reports/inspect-manifest.json")
        var tech = LayoutTechDatabase.standard()
        tech.vias = []
        try defWithViaDefinition.write(to: defURL, atomically: true, encoding: .utf8)
        try LayoutDocumentSerializer().encodeTech(tech).write(to: techURL, options: .atomic)
        return RoutingFixture(
            directory: directory,
            defURL: defURL,
            techURL: techURL,
            inspectionResultURL: inspectionResultURL,
            inspectionManifestURL: inspectionManifestURL
        )
    }

    private static func simpleDocument() -> LayoutDocument {
        let top = LayoutCell(
            name: "TOP",
            shapes: [
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .rect(LayoutRect(
                        origin: LayoutPoint(x: 0, y: 0),
                        size: LayoutSize(width: 1, height: 0.5)
                    ))
                ),
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .polygon(LayoutPolygon(points: [
                        LayoutPoint(x: 2, y: 0),
                        LayoutPoint(x: 3, y: 0),
                        LayoutPoint(x: 3, y: 0.5),
                        LayoutPoint(x: 2, y: 0.5),
                    ]))
                ),
                LayoutShape(
                    layer: LayoutLayerID(name: "M1", purpose: "drawing"),
                    geometry: .path(LayoutPath(
                        points: [
                            LayoutPoint(x: 4, y: 0),
                            LayoutPoint(x: 5, y: 0),
                            LayoutPoint(x: 5, y: 0.5),
                        ],
                        width: 0.2,
                        endCap: .extend
                    ))
                ),
            ]
        )
        return LayoutDocument(name: "simple", cells: [top], topCellID: top.id)
    }

    private static func strictM1Tech() -> LayoutTechDatabase {
        var tech = LayoutTechDatabase.standard()
        tech.layerRules = tech.layerRules.map { rule in
            guard rule.layerID == LayoutLayerID(name: "M1", purpose: "drawing") else {
                return rule
            }
            var strictRule = rule
            strictRule.minWidth = 2.0
            return strictRule
        }
        return tech
    }

    private static func placementDocument() -> LayoutDocument {
        let child = LayoutCell(name: "INV")
        let instance = LayoutInstance(
            cellID: child.id,
            name: "u1",
            transform: LayoutTransform(
                translation: LayoutPoint(x: 1.25, y: 2.5),
                rotation: .deg0,
                mirrorX: true
            )
        )
        let top = LayoutCell(name: "TOP", instances: [instance])
        return LayoutDocument(name: "placement", cells: [child, top], topCellID: top.id)
    }

    private static let routedDEF = """
    VERSION 5.8 ;
    DESIGN routed ;
    UNITS DISTANCE MICRONS 1000 ;
    VIAS 1 ;
      - VIA1 + CUTSIZE 50 50 + CUTSPACING 100 100 + ENCLOSURE 10 10 10 10 + RECT metal1 ( -35 -35 ) ( 35 35 ) + RECT via1 ( -25 -25 ) ( 25 25 ) + RECT metal2 ( -35 -35 ) ( 35 35 ) ;
    END VIAS
    NETS 1 ;
      - clk ( PIN clk ) + USE CLOCK + ROUTED metal1 ( 100 200 ) ( 900 200 ) VIA1 + NEW metal2 ( 900 200 ) ( 1200 200 ) ;
    END NETS
    SPECIALNETS 1 ;
      - VDD ( * VDD ) + USE POWER + ROUTED metal2 300 + SHAPE STRIPE ( 0 1000 ) ( 1000 * ) VIA1 + NEW metal1 300 + SHAPE STRIPE ( 1000 1000 ) ( 1200 1000 ) ;
    END SPECIALNETS
    END DESIGN
    """

    private static let defWithViaDefinition = """
    VERSION 5.8 ;
    DESIGN via_definition ;
    UNITS DISTANCE MICRONS 1000 ;
    VIAS 1 ;
      - DEFVIA + CUTSIZE 50 50 + CUTSPACING 100 120 + ENCLOSURE 35 25 45 40 + RECT metal1 ( -60 -50 ) ( 60 50 ) + RECT via1 ( -25 -25 ) ( 25 25 ) + RECT metal2 ( -70 -65 ) ( 70 65 ) ;
    END VIAS
    NETS 1 ;
      - sig ( PIN sig ) + ROUTED metal1 ( 100 200 ) ( 900 200 ) DEFVIA ;
    END NETS
    END DESIGN
    """

    private static func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
