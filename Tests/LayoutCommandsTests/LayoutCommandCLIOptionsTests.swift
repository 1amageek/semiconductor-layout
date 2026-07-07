import Foundation
import LayoutCommands
import Testing

@Suite("Layout command CLI options")
struct LayoutCommandCLIOptionsTests {
    @Test("CLI options parse request path and JSON flag")
    func parsesRequestPathAndJSONFlag() throws {
        let options = try LayoutCommandCLIOptions(arguments: ["--request", "/tmp/request.json", "--json"])
        #expect(options.requestPath == "/tmp/request.json")
        #expect(options.mode == .runRequest("/tmp/request.json"))
        #expect(options.emitsJSON)
    }

    @Test("CLI options parse action-domain mode")
    func parsesActionDomainMode() throws {
        let options = try LayoutCommandCLIOptions(arguments: ["--action-domain", "--json"])
        #expect(options.mode == .emitActionDomain)
        #expect(options.requestPath == nil)
        #expect(options.emitsJSON)
    }

    @Test("CLI options parse document conversion mode")
    func parsesDocumentConversionMode() throws {
        let options = try LayoutCommandCLIOptions(arguments: [
            "--convert-document",
            "--input",
            "/tmp/input.json",
            "--input-format",
            "json",
            "--output",
            "/tmp/output.gds",
            "--output-format",
            "gds",
            "--tech",
            "/tmp/tech.json",
            "--result",
            "/tmp/convert-result.json",
            "--artifact-manifest",
            "/tmp/convert-manifest.json",
            "--json",
        ])
        #expect(options.mode == .convertDocument(LayoutDocumentConversionRequest(
            inputPath: "/tmp/input.json",
            inputFormat: .json,
            outputPath: "/tmp/output.gds",
            outputFormat: .gds,
            technologyPath: "/tmp/tech.json",
            resultPath: "/tmp/convert-result.json",
            artifactManifestPath: "/tmp/convert-manifest.json"
        )))
        #expect(options.emitsJSON)
    }

    @Test("CLI options parse document inspection mode")
    func parsesDocumentInspectionMode() throws {
        let options = try LayoutCommandCLIOptions(arguments: [
            "--inspect-document",
            "--input",
            "/tmp/input.oas",
            "--input-format",
            "oasis",
            "--tech",
            "/tmp/tech.lef",
            "--result",
            "/tmp/inspect-result.json",
            "--artifact-manifest",
            "/tmp/inspect-manifest.json",
        ])
        #expect(options.mode == .inspectDocument(LayoutDocumentInspectionRequest(
            inputPath: "/tmp/input.oas",
            inputFormat: .oasis,
            technologyPath: "/tmp/tech.lef",
            resultPath: "/tmp/inspect-result.json",
            artifactManifestPath: "/tmp/inspect-manifest.json"
        )))
        #expect(!options.emitsJSON)
    }

    @Test("CLI options require a command mode")
    func requiresCommandMode() {
        #expect(throws: LayoutCommandError.missingCommandMode) {
            _ = try LayoutCommandCLIOptions(arguments: ["--json"])
        }
    }

    @Test("CLI options require a request path value")
    func requiresRequestPathValue() {
        #expect(throws: LayoutCommandError.missingValueAfter("--request")) {
            _ = try LayoutCommandCLIOptions(arguments: ["--request"])
        }
    }

    @Test("CLI options reject empty required values")
    func rejectsEmptyRequiredValues() {
        #expect(throws: LayoutCommandError.missingValueAfter("--request")) {
            _ = try LayoutCommandCLIOptions(arguments: ["--request", ""])
        }
    }

    @Test("CLI options reject option tokens as required values")
    func rejectsOptionTokensAsRequiredValues() {
        let cases: [([String], LayoutCommandError)] = [
            (["--request", "--json"], .missingValueAfter("--request")),
            (["--inspect-document", "--input", "--json"], .missingValueAfter("--input")),
            (
                ["--inspect-document", "--input", "/tmp/input.oas", "--input-format", "--json"],
                .missingValueAfter("--input-format")
            ),
            (
                ["--convert-document", "--input", "/tmp/input.json", "--input-format", "json", "--output", "--json"],
                .missingValueAfter("--output")
            ),
        ]

        for (arguments, expectedError) in cases {
            #expect(throws: expectedError) {
                _ = try LayoutCommandCLIOptions(arguments: arguments)
            }
        }
    }

    @Test("CLI options reject duplicate arguments instead of silently overriding")
    func rejectsDuplicateArguments() {
        let cases: [([String], LayoutCommandError)] = [
            (["--request", "/tmp/request-a.json", "--request", "/tmp/request-b.json"], .duplicateArgument("--request")),
            (["--action-domain", "--json", "--json"], .duplicateArgument("--json")),
            (
                ["--inspect-document", "--input", "/tmp/input-a.oas", "--input", "/tmp/input-b.oas"],
                .duplicateArgument("--input")
            ),
        ]

        for (arguments, expectedError) in cases {
            #expect(throws: expectedError) {
                _ = try LayoutCommandCLIOptions(arguments: arguments)
            }
        }
    }

    @Test("CLI options reject unknown arguments")
    func rejectsUnknownArguments() {
        #expect(throws: LayoutCommandError.unknownArgument("--unexpected")) {
            _ = try LayoutCommandCLIOptions(arguments: ["--unexpected"])
        }
    }

    @Test("CLI options reject invalid formats")
    func rejectsInvalidFormats() {
        #expect(throws: LayoutCommandError.invalidFormat("unknown")) {
            _ = try LayoutCommandCLIOptions(arguments: [
                "--inspect-document",
                "--input",
                "/tmp/input.layout",
                "--input-format",
                "unknown",
            ])
        }
    }

    @Test("CLI options reject conflicting modes")
    func rejectsConflictingModes() {
        #expect(throws: LayoutCommandError.conflictingArguments("--request", "--action-domain")) {
            _ = try LayoutCommandCLIOptions(arguments: [
                "--request",
                "/tmp/request.json",
                "--action-domain",
            ])
        }
    }

    @Test("CLI JSON failure output is structured for developer diagnostics")
    func rendersStructuredJSONFailureOutput() throws {
        let output = try LayoutCommandFailureRenderer().jsonString(
            for: LayoutCommandError.missingDocumentIDForNewDocument
        )
        let data = try #require(output.data(using: .utf8))
        let failure = try JSONDecoder().decode(LayoutCommandFailureOutput.self, from: data)

        #expect(failure.schemaVersion == 1)
        #expect(failure.status == "failed")
        #expect(failure.errorCode == "missing_document_id_for_new_document")
        #expect(failure.reason == "missing_input")
        #expect(failure.message == "documentID is required when inputDocumentPath is not provided")
        #expect(failure.suggestedActions.contains("provide-document-id"))
    }

    @Test("CLI JSON failure output includes invalid format code")
    func rendersInvalidFormatFailureOutput() throws {
        let output = try LayoutCommandFailureRenderer().jsonString(
            for: LayoutCommandError.invalidFormat("binary")
        )
        let data = try #require(output.data(using: .utf8))
        let failure = try JSONDecoder().decode(LayoutCommandFailureOutput.self, from: data)

        #expect(failure.errorCode == "invalid_format")
        #expect(failure.reason == "invalid_cli_argument")
        #expect(failure.message == "Invalid layout file format: binary")
        #expect(failure.suggestedActions.contains("select-supported-layout-format"))
    }

    @Test("CLI JSON failure output includes duplicate argument code")
    func rendersDuplicateArgumentFailureOutput() throws {
        let output = try LayoutCommandFailureRenderer().jsonString(
            for: LayoutCommandError.duplicateArgument("--request")
        )
        let data = try #require(output.data(using: .utf8))
        let failure = try JSONDecoder().decode(LayoutCommandFailureOutput.self, from: data)

        #expect(failure.errorCode == "duplicate_argument")
        #expect(failure.reason == "duplicate_identifier")
        #expect(failure.message == "Duplicate argument: --request")
        #expect(failure.suggestedActions.contains("remove-duplicate-cli-argument"))
    }

    @Test("CLI JSON failure output includes validation remediation actions")
    func rendersValidationRemediationFailureOutput() throws {
        let missingNetID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
        let output = try LayoutCommandFailureRenderer().jsonString(
            for: LayoutCommandError.netNotFound(missingNetID)
        )
        let data = try #require(output.data(using: .utf8))
        let failure = try JSONDecoder().decode(LayoutCommandFailureOutput.self, from: data)

        #expect(failure.errorCode == "net_not_found")
        #expect(failure.reason == "missing_reference")
        #expect(failure.suggestedActions.contains("inspect-cell-nets"))
        #expect(failure.suggestedActions.contains("create-net-before-reference"))
    }

    @Test("CLI JSON failure output includes geometry remediation actions")
    func rendersGeometryRemediationFailureOutput() throws {
        let output = try LayoutCommandFailureRenderer().jsonString(
            for: LayoutCommandError.invalidShapeGeometry(kind: "polygon")
        )
        let data = try #require(output.data(using: .utf8))
        let failure = try JSONDecoder().decode(LayoutCommandFailureOutput.self, from: data)

        #expect(failure.errorCode == "invalid_shape_geometry")
        #expect(failure.reason == "invalid_geometry")
        #expect(failure.suggestedActions.contains("repair-shape-geometry"))
        #expect(failure.suggestedActions.contains("use-positive-area-polygon-or-length-path"))
    }
}
