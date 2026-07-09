import Foundation
import CryptoKit
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify

public struct LayoutCommandCLIService: Sendable {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let serializer: LayoutDocumentSerializer
    private let runner: LayoutCommandRunner
    private let actionDomainExporter: LayoutActionDomainExporter

    public init(
        serializer: LayoutDocumentSerializer = LayoutDocumentSerializer(),
        runner: LayoutCommandRunner = LayoutCommandRunner(),
        actionDomainExporter: LayoutActionDomainExporter = LayoutActionDomainExporter()
    ) {
        self.decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.serializer = serializer
        self.runner = runner
        self.actionDomainExporter = actionDomainExporter
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
            "layout-command \(result.status): \(result.commandCount) commands, \(result.shapeCount) shapes, \(result.outputDocumentPath)",
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
        let pathPlan = try LayoutCommandArtifactPathPlan.conversion(request)
        guard let outputURL = pathPlan.outputURL else {
            throw LayoutCommandError.missingRequiredArgument("--output")
        }
        let inputData = try Data(contentsOf: pathPlan.inputURL)
        let effectiveTech = try loadEffectiveTechnology(
            inputURL: pathPlan.inputURL,
            inputFormat: request.inputFormat,
            outputFormat: request.outputFormat,
            technologyPath: request.technologyPath
        )
        let document = try loadDocument(from: pathPlan.inputURL, format: request.inputFormat, tech: effectiveTech)
        try writeConvertedDocument(document, to: outputURL, format: request.outputFormat, tech: effectiveTech)
        let outputData = try Data(contentsOf: outputURL)
        let result = makeConversionResult(
            request: request,
            pathPlan: pathPlan,
            inputData: inputData,
            outputData: outputData,
            document: document
        )
        let resultData = try encoder.encode(result)
        let artifacts = try conversionArtifacts(
            request: request,
            resultData: resultData,
            pathPlan: pathPlan,
            inputData: inputData,
            outputData: outputData
        )
        try writeManifestIfRequested(artifacts: artifacts, to: pathPlan.manifestURL)

        return renderConversion(result: result, resultData: resultData, emitsJSON: emitsJSON)
    }

    private func inspectDocument(
        _ request: LayoutDocumentInspectionRequest,
        emitsJSON: Bool
    ) throws -> (output: String, status: String) {
        let pathPlan = try LayoutCommandArtifactPathPlan.inspection(request)
        let inputData = try Data(contentsOf: pathPlan.inputURL)
        let effectiveTech = try loadEffectiveTechnology(
            inputURL: pathPlan.inputURL,
            inputFormat: request.inputFormat,
            outputFormat: .json,
            technologyPath: request.technologyPath
        )
        let document = try loadDocument(from: pathPlan.inputURL, format: request.inputFormat, tech: effectiveTech)
        let verification = try inspectionVerification(document: document, tech: effectiveTech)
        let result = LayoutDocumentInspectionResult(
            inputPath: pathPlan.inputURL.path,
            inputFormat: request.inputFormat,
            technologyPath: request.technologyPath,
            inputSHA256: Self.sha256Hex(inputData),
            inputByteCount: inputData.count,
            resultPath: pathPlan.resultURL?.path,
            artifactManifestPath: pathPlan.manifestURL?.path,
            summary: LayoutDocumentSummary(document: document),
            verification: verification
        )
        let resultData = try encoder.encode(result)
        var artifacts = [
            LayoutCommandArtifact(
                id: "input-layout-document",
                kind: "layout",
                format: Self.artifactFormat(for: request.inputFormat),
                path: pathPlan.inputURL.path,
                sha256: Self.sha256Hex(inputData),
                byteCount: inputData.count
            ),
        ]
        if let technologyArtifact = try technologyArtifact(path: request.technologyPath) {
            artifacts.append(technologyArtifact)
        }
        if let resultArtifact = try writeArtifact(
            id: "layout-inspection-result",
            kind: "result",
            format: "LayoutDocumentInspectionResultJSON",
            url: pathPlan.resultURL,
            data: resultData
        ) {
            artifacts.append(resultArtifact)
        }
        try writeManifestIfRequested(artifacts: artifacts, to: pathPlan.manifestURL)

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
        let pathPlan = try LayoutCommandArtifactPathPlan.constraintValidation(request)
        let inputData = try Data(contentsOf: pathPlan.inputURL)
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
        let result = LayoutConstraintValidationResult(
            inputPath: pathPlan.inputURL.path,
            inputFormat: request.inputFormat,
            technologyPath: request.technologyPath,
            inputSHA256: Self.sha256Hex(inputData),
            inputByteCount: inputData.count,
            resultPath: pathPlan.resultURL?.path,
            artifactManifestPath: pathPlan.manifestURL?.path,
            summary: LayoutDocumentSummary(document: document),
            validation: validation
        )
        let resultData = try encoder.encode(result)
        var artifacts = [
            LayoutCommandArtifact(
                id: "input-layout-document",
                kind: "layout",
                format: Self.artifactFormat(for: request.inputFormat),
                path: pathPlan.inputURL.path,
                sha256: Self.sha256Hex(inputData),
                byteCount: inputData.count
            ),
        ]
        if let technologyArtifact = try technologyArtifact(path: request.technologyPath) {
            artifacts.append(technologyArtifact)
        }
        if let resultArtifact = try writeArtifact(
            id: "layout-constraint-validation-result",
            kind: "result",
            format: "LayoutConstraintValidationResultJSON",
            url: pathPlan.resultURL,
            data: resultData
        ) {
            artifacts.append(resultArtifact)
        }
        try writeManifestIfRequested(artifacts: artifacts, to: pathPlan.manifestURL)

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
        let inputData = try Data(contentsOf: inputURL)
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
        let result = LayoutConnectivityDiagnosisResult(
            inputPath: inputURL.path,
            inputFormat: request.inputFormat,
            technologyPath: request.technologyPath,
            inputSHA256: Self.sha256Hex(inputData),
            inputByteCount: inputData.count,
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
        request: LayoutDocumentConversionRequest,
        pathPlan: LayoutCommandArtifactPathPlan,
        inputData: Data,
        outputData: Data,
        document: LayoutDocument
    ) -> LayoutDocumentConversionResult {
        LayoutDocumentConversionResult(
            inputPath: pathPlan.inputURL.path,
            inputFormat: request.inputFormat,
            outputPath: pathPlan.outputURL?.path ?? request.outputPath,
            outputFormat: request.outputFormat,
            technologyPath: request.technologyPath,
            inputSHA256: Self.sha256Hex(inputData),
            inputByteCount: inputData.count,
            outputSHA256: Self.sha256Hex(outputData),
            outputByteCount: outputData.count,
            resultPath: pathPlan.resultURL?.path,
            artifactManifestPath: pathPlan.manifestURL?.path,
            summary: LayoutDocumentSummary(document: document)
        )
    }

    private func conversionArtifacts(
        request: LayoutDocumentConversionRequest,
        resultData: Data,
        pathPlan: LayoutCommandArtifactPathPlan,
        inputData: Data,
        outputData: Data
    ) throws -> [LayoutCommandArtifact] {
        var artifacts = [
            LayoutCommandArtifact(
                id: "input-layout-document",
                kind: "layout",
                format: Self.artifactFormat(for: request.inputFormat),
                path: pathPlan.inputURL.path,
                sha256: Self.sha256Hex(inputData),
                byteCount: inputData.count
            ),
            LayoutCommandArtifact(
                id: "output-layout-document",
                kind: "layout",
                format: Self.artifactFormat(for: request.outputFormat),
                path: pathPlan.outputURL?.path ?? request.outputPath,
                sha256: Self.sha256Hex(outputData),
                byteCount: outputData.count
            ),
        ]
        if let technologyArtifact = try technologyArtifact(path: request.technologyPath) {
            artifacts.append(technologyArtifact)
        }
        if let resultArtifact = try writeArtifact(
            id: "layout-conversion-result",
            kind: "result",
            format: "LayoutDocumentConversionResultJSON",
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
        layout-command convert-document passed: \(result.inputFormat.rawValue) -> \(result.outputFormat.rawValue), \(result.summary.cellCount) cells, \(result.summary.shapeCount) shapes, \(result.outputPath)
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
        let errors = drcResult.violations.filter { $0.severity == .error }
        let warnings = drcResult.violations.filter { $0.severity == .warning }
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
            status: errors.isEmpty ? "passed" : "failed",
            topCellID: topCellID,
            drc: LayoutDocumentInspectionDRCSummary(
                violationCount: drcResult.violations.count,
                errorCount: errors.count,
                warningCount: warnings.count,
                ruleViolationCounts: ruleCounts,
                kindViolationCounts: kindCounts,
                violations: violations
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

    private func technologyArtifact(path: String?) throws -> LayoutCommandArtifact? {
        guard let path else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return LayoutCommandArtifact(
            id: "technology-profile",
            kind: "technology",
            format: url.pathExtension.isEmpty ? "TechnologyProfile" : url.pathExtension.uppercased(),
            path: url.path,
            sha256: Self.sha256Hex(data),
            byteCount: data.count
        )
    }

    private func writeArtifact(
        id: String,
        kind: String,
        format: String,
        url: URL?,
        data: Data
    ) throws -> LayoutCommandArtifact? {
        guard let url else {
            return nil
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return LayoutCommandArtifact(
            id: id,
            kind: kind,
            format: format,
            path: url.path,
            sha256: Self.sha256Hex(data),
            byteCount: data.count
        )
    }

    private func writeManifestIfRequested(artifacts: [LayoutCommandArtifact], to url: URL?) throws {
        guard let url else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(LayoutCommandArtifactManifest(artifacts: artifacts))
        try data.write(to: url, options: .atomic)
    }

    private static func artifactFormat(for format: LayoutFileFormat) -> String {
        switch format {
        case .json:
            return "LayoutDocumentJSON"
        default:
            return format.rawValue.uppercased()
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func jsonString(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
