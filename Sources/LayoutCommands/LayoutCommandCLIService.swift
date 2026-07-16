import CircuiteFoundation
import Foundation
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify

public struct LayoutCommandCLIService: Sendable {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let serializer: LayoutDocumentSerializer
    private let runner: any LayoutCommandRunning
    private let actionDomainExporter: LayoutActionDomainExporter
    private let artifactReferencer: any ArtifactReferencing

    public init(
        serializer: LayoutDocumentSerializer = LayoutDocumentSerializer(),
        runner: any LayoutCommandRunning = LayoutCommandRunner(),
        actionDomainExporter: LayoutActionDomainExporter = LayoutActionDomainExporter(),
        artifactReferencer: any ArtifactReferencing = LocalArtifactReferencer()
    ) {
        self.decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.serializer = serializer
        self.runner = runner
        self.actionDomainExporter = actionDomainExporter
        self.artifactReferencer = artifactReferencer
    }

    public func run(options: LayoutCommandCLIOptions) throws -> String {
        try runWithExitStatus(options: options).output
    }

    public func runWithExitStatus(options: LayoutCommandCLIOptions) throws -> (output: String, exitCode: Int32) {
        switch options.mode {
        case .runRequest(let requestPath):
            let response = try runRequest(requestPath: requestPath, emitsJSON: options.emitsJSON)
            return (response.output, response.status == "passed" ? 0 : 1)
        case .emitActionDomain:
            return (try emitActionDomain(emitsJSON: options.emitsJSON), 0)
        case .convertDocument(let request):
            return (try convertDocument(request, emitsJSON: options.emitsJSON), 0)
        case .inspectDocument(let request):
            let response = try inspectDocument(request, emitsJSON: options.emitsJSON)
            return (response.output, response.status == "passed" ? 0 : 1)
        case .validateConstraints(let request):
            return try validateConstraints(request, emitsJSON: options.emitsJSON)
        case .diagnoseConnectivity(let request):
            return try diagnoseConnectivity(request, emitsJSON: options.emitsJSON)
        }
    }

    private func runRequest(requestPath: String, emitsJSON: Bool) throws -> (output: String, status: String) {
        let requestURL = URL(fileURLWithPath: requestPath)
        let data = try Data(contentsOf: requestURL)
        let request = try decoder.decode(LayoutCommandRequest.self, from: data)
        let result = try runner.run(
            request: request,
            baseURL: requestURL.deletingLastPathComponent()
        )

        if emitsJSON {
            return (jsonString(from: try encoder.encode(result)), result.status)
        }

        return (
            "layout-command \(result.status): \(result.commandCount) commands, \(result.shapeCount) shapes, \(result.outputArtifact.path)",
            result.status
        )
    }

    private func emitActionDomain(emitsJSON: Bool) throws -> String {
        let snapshot = actionDomainExporter.snapshot()
        if emitsJSON {
            return jsonString(from: try encoder.encode(snapshot))
        }
        return "layout-command action-domain \(snapshot.domainID): \(snapshot.operations.count) operations"
    }

    private func convertDocument(_ request: LayoutDocumentConversionRequest, emitsJSON: Bool) throws -> String {
        let startedAt = Date()
        let pathPlan = try LayoutCommandOutputPathPlan.conversion(request)
        guard let outputURL = pathPlan.outputURL else {
            throw LayoutCommandError.missingRequiredArgument("--output")
        }
        let effectiveTech = try loadEffectiveTechnology(
            inputURL: pathPlan.inputURL,
            inputFormat: request.inputFormat,
            outputFormat: request.outputFormat,
            technologyPath: request.technologyPath
        )
        let document = try loadDocument(from: pathPlan.inputURL, format: request.inputFormat, tech: effectiveTech)
        try writeConvertedDocument(document, to: outputURL, format: request.outputFormat, tech: effectiveTech)
        let inputArtifact = try referenceArtifact(
            at: pathPlan.inputURL,
            role: "input-layout-document",
            kind: .layout,
            format: try Self.artifactFormat(for: request.inputFormat)
        )
        let outputArtifact = try referenceArtifact(
            at: outputURL,
            role: "output-layout-document",
            kind: .layout,
            format: try Self.artifactFormat(for: request.outputFormat),
            producer: try producerIdentity()
        )
        let technologyArtifact = try technologyArtifact(path: request.technologyPath)
        let result = makeConversionResult(
            inputArtifact: inputArtifact,
            outputArtifact: outputArtifact,
            technologyArtifact: technologyArtifact,
            document: document
        )
        let resultData = try encoder.encode(result)
        let artifacts = try conversionArtifacts(
            resultData: resultData,
            pathPlan: pathPlan,
            inputArtifact: inputArtifact,
            outputArtifact: outputArtifact,
            technologyArtifact: technologyArtifact
        )
        try writeManifestIfRequested(
            artifacts: artifacts,
            inputs: [inputArtifact] + [technologyArtifact].compactMap { $0 },
            to: pathPlan.manifestURL,
            entryPoint: "LayoutCommandCLIService.convertDocument",
            startedAt: startedAt
        )

        return renderConversion(result: result, resultData: resultData, emitsJSON: emitsJSON)
    }

    private func inspectDocument(
        _ request: LayoutDocumentInspectionRequest,
        emitsJSON: Bool
    ) throws -> (output: String, status: String) {
        let startedAt = Date()
        let pathPlan = try LayoutCommandOutputPathPlan.inspection(request)
        let effectiveTech = try loadEffectiveTechnology(
            inputURL: pathPlan.inputURL,
            inputFormat: request.inputFormat,
            outputFormat: .json,
            technologyPath: request.technologyPath
        )
        let document = try loadDocument(from: pathPlan.inputURL, format: request.inputFormat, tech: effectiveTech)
        let verification = try inspectionVerification(document: document, tech: effectiveTech)
        let inputArtifact = try referenceArtifact(
            at: pathPlan.inputURL,
            role: "input-layout-document",
            kind: .layout,
            format: try Self.artifactFormat(for: request.inputFormat)
        )
        let technologyArtifact = try technologyArtifact(path: request.technologyPath)
        let result = LayoutDocumentInspectionResult(
            inputArtifact: inputArtifact,
            technologyArtifact: technologyArtifact,
            summary: LayoutDocumentSummary(document: document),
            verification: verification
        )
        let resultData = try encoder.encode(result)
        var artifacts = [inputArtifact]
        if let technologyArtifact { artifacts.append(technologyArtifact) }
        if let resultArtifact = try writeArtifact(
            role: "layout-inspection-result",
            kind: .report,
            format: .json,
            url: pathPlan.resultURL,
            data: resultData
        ) {
            artifacts.append(resultArtifact)
        }
        try writeManifestIfRequested(
            artifacts: artifacts,
            inputs: [inputArtifact] + [technologyArtifact].compactMap { $0 },
            to: pathPlan.manifestURL,
            entryPoint: "LayoutCommandCLIService.inspectDocument",
            startedAt: startedAt
        )

        if emitsJSON {
            return (jsonString(from: resultData), result.status)
        }
        return (
            """
            layout-command inspect-document \(result.status): \(request.inputFormat.rawValue), \(result.summary.cellCount) cells, \(result.summary.shapeCount) shapes, \(result.summary.viaCount) vias
            """,
            result.status
        )
    }

    private func validateConstraints(
        _ request: LayoutConstraintValidationRequest,
        emitsJSON: Bool
    ) throws -> (output: String, exitCode: Int32) {
        let startedAt = Date()
        let pathPlan = try LayoutCommandOutputPathPlan.constraintValidation(request)
        let effectiveTech = try loadEffectiveTechnology(
            inputURL: pathPlan.inputURL,
            inputFormat: request.inputFormat,
            outputFormat: .json,
            technologyPath: request.technologyPath
        )
        let document = try loadDocument(from: pathPlan.inputURL, format: request.inputFormat, tech: effectiveTech)
        let cellID = try validationCellID(request.cellID, document: document)
        let cell = try validationCell(cellID, document: document)
        let tolerance = request.tolerance ?? 1.0e-9
        let violations = try LayoutConstraintChecker(tolerance: tolerance)
            .check(document: document, cellID: cellID)
        let validation = constraintValidationSummary(
            cell: cell,
            tolerance: tolerance,
            violations: violations
        )
        let inputArtifact = try referenceArtifact(
            at: pathPlan.inputURL,
            role: "input-layout-document",
            kind: .layout,
            format: try Self.artifactFormat(for: request.inputFormat)
        )
        let technologyArtifact = try technologyArtifact(path: request.technologyPath)
        let result = LayoutConstraintValidationResult(
            inputArtifact: inputArtifact,
            technologyArtifact: technologyArtifact,
            summary: LayoutDocumentSummary(document: document),
            validation: validation
        )
        let resultData = try encoder.encode(result)
        var artifacts = [inputArtifact]
        if let technologyArtifact { artifacts.append(technologyArtifact) }
        if let resultArtifact = try writeArtifact(
            role: "layout-constraint-validation-result",
            kind: .report,
            format: .json,
            url: pathPlan.resultURL,
            data: resultData
        ) {
            artifacts.append(resultArtifact)
        }
        try writeManifestIfRequested(
            artifacts: artifacts,
            inputs: [inputArtifact] + [technologyArtifact].compactMap { $0 },
            to: pathPlan.manifestURL,
            entryPoint: "LayoutCommandCLIService.validateConstraints",
            startedAt: startedAt
        )

        let exitCode: Int32 = result.status == "failed" ? 2 : 0
        if emitsJSON {
            return (jsonString(from: resultData), exitCode)
        }
        return (
            """
            layout-command validate-constraints \(result.status): \(validation.constraintCount) constraints, \
            \(validation.errorCount) errors, \(validation.warningCount) warnings
            """,
            exitCode
        )
    }

    /// Runs the connectivity diagnosis and folds its verdict into the exit
    /// code: 0 when fully connected, 2 when opens or shorts are present.
    /// Unlike `--inspect-document`, connectivity IS the output here, so a
    /// technology profile is required for every input format — a report
    /// silently missing its analysis would be a non-answer.
    private func diagnoseConnectivity(
        _ request: LayoutConnectivityDiagnosisRequest,
        emitsJSON: Bool
    ) throws -> (output: String, exitCode: Int32) {
        let inputURL = URL(fileURLWithPath: request.inputPath)
        guard let tech = try loadEffectiveTechnology(
            inputURL: inputURL,
            inputFormat: request.inputFormat,
            outputFormat: request.inputFormat,
            technologyPath: request.technologyPath
        ) else {
            throw LayoutCommandError.missingRequiredArgument("--tech")
        }
        let document = try loadDocument(from: inputURL, format: request.inputFormat, tech: tech)
        let diagnosis = try LayoutConnectivityDiagnoser().diagnose(document: document, tech: tech)
        let inputArtifact = try referenceArtifact(
            at: inputURL,
            role: "input-layout-document",
            kind: .layout,
            format: try Self.artifactFormat(for: request.inputFormat)
        )
        let technologyArtifact = try technologyArtifact(path: request.technologyPath)
        let result = LayoutConnectivityDiagnosisResult(
            inputArtifact: inputArtifact,
            technologyArtifact: technologyArtifact,
            diagnosis: diagnosis
        )
        let exitCode: Int32 = result.status == "passed" ? 0 : 2

        if emitsJSON {
            return (jsonString(from: try encoder.encode(result)), exitCode)
        }
        return (
            """
            layout-command diagnose-connectivity \(result.status): \(diagnosis.totals.netCount) nets, \
            \(diagnosis.totals.openCount) opens, \(diagnosis.totals.shortCount) shorts
            """,
            exitCode
        )
    }

    private func loadEffectiveTechnology(
        inputURL: URL,
        inputFormat: LayoutFileFormat,
        outputFormat: LayoutFileFormat,
        technologyPath: String?
    ) throws -> LayoutTechDatabase? {
        let tech = try loadTechnologyIfNeeded(
            path: technologyPath,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
        return try effectiveTechnology(
            for: inputURL,
            format: inputFormat,
            baseTech: tech
        )
    }

    private func writeConvertedDocument(
        _ document: LayoutDocument,
        to outputURL: URL,
        format: LayoutFileFormat,
        tech: LayoutTechDatabase?
    ) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeDocument(document, to: outputURL, format: format, tech: tech)
    }

    private func makeConversionResult(
        inputArtifact: ArtifactReference,
        outputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference?,
        document: LayoutDocument
    ) -> LayoutDocumentConversionResult {
        LayoutDocumentConversionResult(
            inputArtifact: inputArtifact,
            outputArtifact: outputArtifact,
            technologyArtifact: technologyArtifact,
            summary: LayoutDocumentSummary(document: document)
        )
    }

    private func conversionArtifacts(
        resultData: Data,
        pathPlan: LayoutCommandOutputPathPlan,
        inputArtifact: ArtifactReference,
        outputArtifact: ArtifactReference,
        technologyArtifact: ArtifactReference?
    ) throws -> [ArtifactReference] {
        var artifacts = [inputArtifact, outputArtifact]
        if let technologyArtifact {
            artifacts.append(technologyArtifact)
        }
        if let resultArtifact = try writeArtifact(
            role: "layout-conversion-result",
            kind: .report,
            format: .json,
            url: pathPlan.resultURL,
            data: resultData
        ) {
            artifacts.append(resultArtifact)
        }
        return artifacts
    }

    private func renderConversion(
        result: LayoutDocumentConversionResult,
        resultData: Data,
        emitsJSON: Bool
    ) -> String {
        if emitsJSON {
            return jsonString(from: resultData)
        }
        return """
        layout-command convert-document passed: \(result.inputArtifact.format.rawValue) -> \(result.outputArtifact.format.rawValue), \(result.summary.cellCount) cells, \(result.summary.shapeCount) shapes, \(result.outputArtifact.path)
        """
    }

    private func inspectionVerification(
        document: LayoutDocument,
        tech: LayoutTechDatabase?
    ) throws -> LayoutDocumentInspectionVerification? {
        guard let tech,
              let topCellID = document.topCellID ?? document.cells.first?.id else {
            return nil
        }
        let drcResult = LayoutDRCService().run(
            document: document,
            tech: tech,
            cellID: topCellID
        )
        let connectivity = try LayoutConnectivityExtractor().extract(
            document: document,
            tech: tech,
            cellID: topCellID
        )
        let violationErrorCount = drcResult.violations.count { $0.severity == .error }
        let diagnosticErrorCount = drcResult.diagnostics.count { $0.severity == .error }
        let violationWarningCount = drcResult.violations.count { $0.severity == .warning }
        let diagnosticWarningCount = drcResult.diagnostics.count { $0.severity == .warning }
        let ruleCounts = Dictionary(
            grouping: drcResult.violations,
            by: { $0.ruleID ?? "unspecified" }
        ).mapValues(\.count)
        let kindCounts = Dictionary(
            grouping: drcResult.violations,
            by: { $0.kind.rawValue }
        ).mapValues(\.count)
        let violations = drcResult.violations
            .sorted { lhs, rhs in
                if lhs.kind.rawValue == rhs.kind.rawValue {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            .map { violation in
                LayoutDocumentInspectionViolationSummary(
                    id: violation.id,
                    kind: violation.kind.rawValue,
                    ruleID: violation.ruleID,
                    severity: violation.severity.rawValue,
                    message: violation.message,
                    layer: violation.layer,
                    region: violation.region,
                    measured: violation.measured,
                    required: violation.required,
                    unit: violation.unit,
                    shapeIDs: violation.shapeIDs,
                    viaIDs: violation.viaIDs,
                    pinIDs: violation.pinIDs,
                    netIDs: violation.netIDs,
                    suggestedFix: violation.suggestedFix
                )
            }
        return LayoutDocumentInspectionVerification(
            status: drcResult.hasErrors ? "failed" : "passed",
            topCellID: topCellID,
            drc: LayoutDocumentInspectionDRCSummary(
                violationCount: drcResult.violations.count,
                errorCount: violationErrorCount + diagnosticErrorCount,
                warningCount: violationWarningCount + diagnosticWarningCount,
                diagnosticCount: drcResult.diagnostics.count,
                ruleViolationCounts: ruleCounts,
                kindViolationCounts: kindCounts,
                violations: violations,
                diagnostics: drcResult.diagnostics
            ),
            connectivity: LayoutDocumentInspectionConnectivitySummary(
                extractedNetCount: connectivity.nets.count,
                shortCount: connectivity.shorts.count,
                openCount: connectivity.opens.count,
                flylineCount: connectivity.flylines.count
            )
        )
    }

    private func validationCellID(_ requestedCellID: UUID?, document: LayoutDocument) throws -> UUID {
        if let requestedCellID {
            return requestedCellID
        }
        if let topCellID = document.topCellID {
            return topCellID
        }
        guard let firstCellID = document.cells.first?.id else {
            throw LayoutCommandError.missingRequiredArgument("--cell-id")
        }
        return firstCellID
    }

    private func validationCell(_ cellID: UUID, document: LayoutDocument) throws -> LayoutCell {
        guard let cell = document.cell(withID: cellID) else {
            throw LayoutCommandError.cellNotFound(cellID)
        }
        return cell
    }

    private func constraintValidationSummary(
        cell: LayoutCell,
        tolerance: Double,
        violations: [LayoutConstraintViolation]
    ) -> LayoutConstraintValidationSummary {
        let errors = violations.filter { $0.severity == .error }
        let warnings = violations.filter { $0.severity == .warning }
        let status: String
        if !errors.isEmpty {
            status = "failed"
        } else if !warnings.isEmpty {
            status = "warning"
        } else {
            status = "passed"
        }
        let kindCounts = Dictionary(grouping: violations, by: { $0.kind.rawValue }).mapValues(\.count)
        let summaries = violations
            .sorted { lhs, rhs in
                if lhs.constraintIndex != rhs.constraintIndex {
                    return lhs.constraintIndex < rhs.constraintIndex
                }
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(LayoutConstraintViolationSummary.init)
        return LayoutConstraintValidationSummary(
            status: status,
            cellID: cell.id,
            cellName: cell.name,
            tolerance: tolerance,
            constraintCount: cell.constraints.count,
            violationCount: violations.count,
            errorCount: errors.count,
            warningCount: warnings.count,
            kindViolationCounts: kindCounts,
            violations: summaries
        )
    }

    private func loadDocument(from url: URL, format: LayoutFileFormat, tech: LayoutTechDatabase?) throws -> LayoutDocument {
        switch format {
        case .json:
            let data = try Data(contentsOf: url)
            return try serializer.decodeDocument(data)
        default:
            guard let tech else {
                throw LayoutCommandError.missingRequiredArgument("--tech")
            }
            return try MaskDataFormatConverter(tech: tech).importDocument(from: url, format: format)
        }
    }

    private func effectiveTechnology(
        for inputURL: URL,
        format: LayoutFileFormat,
        baseTech: LayoutTechDatabase?
    ) throws -> LayoutTechDatabase? {
        guard format == .def else {
            return baseTech
        }
        guard let baseTech else {
            return nil
        }
        return try MaskDataFormatConverter(tech: baseTech).importTech(from: inputURL, format: .def)
    }

    private func writeDocument(
        _ document: LayoutDocument,
        to url: URL,
        format: LayoutFileFormat,
        tech: LayoutTechDatabase?
    ) throws {
        switch format {
        case .json:
            let data = try serializer.encodeDocument(document)
            try data.write(to: url, options: .atomic)
        default:
            guard let tech else {
                throw LayoutCommandError.missingRequiredArgument("--tech")
            }
            try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        }
    }

    private func loadTechnologyIfNeeded(
        path: String?,
        inputFormat: LayoutFileFormat,
        outputFormat: LayoutFileFormat
    ) throws -> LayoutTechDatabase? {
        guard let path else {
            guard inputFormat != .json || outputFormat != .json else {
                return nil
            }
            throw LayoutCommandError.missingRequiredArgument("--tech")
        }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: url)
            do {
                return try serializer.decodeTech(data)
            } catch {
                do {
                    return try TechFormatConverter().loadTech(from: url)
                } catch {
                    throw LayoutIOError.readFailed("Failed to decode technology profile at \(url.path)")
                }
            }
        }
        return try TechFormatConverter().loadTech(from: url)
    }

    private func technologyArtifact(path: String?) throws -> ArtifactReference? {
        guard let path else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let format: ArtifactFormat
        if url.pathExtension.isEmpty {
            format = .unknown
        } else {
            format = try ArtifactFormat(rawValue: url.pathExtension.lowercased())
        }
        return try referenceArtifact(
            at: url,
            role: "technology-profile",
            kind: .technology,
            format: format
        )
    }

    private func writeArtifact(
        role: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        url: URL?,
        data: Data
    ) throws -> ArtifactReference? {
        guard let url else {
            return nil
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return try referenceArtifact(
            at: url,
            role: role,
            kind: kind,
            format: format,
            producer: try producerIdentity()
        )
    }

    private func writeManifestIfRequested(
        artifacts: [ArtifactReference],
        inputs: [ArtifactReference],
        to url: URL?,
        entryPoint: String,
        startedAt: Date
    ) throws {
        guard let url else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let producer = try producerIdentity()
        let provenance = try ExecutionProvenance(
            producer: producer,
            inputs: inputs,
            invocation: try ExecutionInvocation.inProcess(entryPoint: entryPoint),
            startedAt: startedAt,
            completedAt: Date()
        )
        let data = try encoder.encode(EvidenceManifest(provenance: provenance, artifacts: artifacts))
        try data.write(to: url, options: .atomic)
    }

    private func referenceArtifact(
        at url: URL,
        role: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        producer: ProducerIdentity? = nil
    ) throws -> ArtifactReference {
        let locator = ArtifactLocator(
            location: try ArtifactLocation(fileURL: url),
            role: try ArtifactRole(validatingRawValue: role),
            kind: kind,
            format: format
        )
        return try artifactReferencer.reference(locator, relativeTo: nil, producer: producer)
    }

    private func producerIdentity() throws -> ProducerIdentity {
        try ProducerIdentity(kind: .tool, identifier: "layout-command", version: "2")
    }

    private static func artifactFormat(for format: LayoutFileFormat) throws -> ArtifactFormat {
        switch format {
        case .json:
            return .json
        case .gds:
            return .gdsii
        case .oasis:
            return .oasis
        case .lef:
            return .lef
        case .def:
            return .def
        case .cif, .dxf, .odb:
            return try ArtifactFormat(rawValue: format.rawValue)
        }
    }

    private func jsonString(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
