import Foundation
import LayoutIO

public struct LayoutCommandCLIOptions: Sendable, Equatable {
    public let mode: LayoutCommandCLIMode
    public let emitsJSON: Bool

    public var requestPath: String? {
        if case .runRequest(let path) = mode {
            return path
        }
        return nil
    }

    public init(arguments: [String]) throws {
        let parsed = try Self.parseArguments(arguments)
        mode = try Self.makeMode(from: parsed)
        emitsJSON = parsed.emitsJSON
    }

    private struct ParsedArguments {
        var requestPath: String?
        var emitsActionDomain = false
        var convertsDocument = false
        var inspectsDocument = false
        var diagnosesConnectivity = false
        var inputPath: String?
        var inputFormat: LayoutFileFormat?
        var outputPath: String?
        var outputFormat: LayoutFileFormat?
        var technologyPath: String?
        var resultPath: String?
        var artifactManifestPath: String?
        var emitsJSON = false
        var selectedModes: [String] = []
        private var seenOptions: Set<String> = []

        mutating func markOption(_ option: String) throws {
            guard seenOptions.insert(option).inserted else {
                throw LayoutCommandError.duplicateArgument(option)
            }
        }

        mutating func selectMode(_ option: String) {
            selectedModes.append(option)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
        var cursor = LayoutCommandCLIArgumentCursor(arguments: arguments)
        var parsed = ParsedArguments()

        while let argument = cursor.next() {
            try parsed.markOption(argument)
            switch argument {
            case "--request":
                parsed.requestPath = try cursor.requireValue(for: argument)
                parsed.selectMode(argument)
            case "--action-domain":
                parsed.emitsActionDomain = true
                parsed.selectMode(argument)
            case "--convert-document":
                parsed.convertsDocument = true
                parsed.selectMode(argument)
            case "--inspect-document":
                parsed.inspectsDocument = true
                parsed.selectMode(argument)
            case "--diagnose-connectivity":
                parsed.diagnosesConnectivity = true
                parsed.selectMode(argument)
            case "--input":
                parsed.inputPath = try cursor.requireValue(for: argument)
            case "--input-format":
                parsed.inputFormat = try parseFormat(cursor.requireValue(for: argument))
            case "--output":
                parsed.outputPath = try cursor.requireValue(for: argument)
            case "--output-format":
                parsed.outputFormat = try parseFormat(cursor.requireValue(for: argument))
            case "--tech":
                parsed.technologyPath = try cursor.requireValue(for: argument)
            case "--result":
                parsed.resultPath = try cursor.requireValue(for: argument)
            case "--artifact-manifest":
                parsed.artifactManifestPath = try cursor.requireValue(for: argument)
            case "--json":
                parsed.emitsJSON = true
            default:
                throw LayoutCommandError.unknownArgument(argument)
            }
        }
        return parsed
    }

    private static func makeMode(from parsed: ParsedArguments) throws -> LayoutCommandCLIMode {
        if parsed.selectedModes.count > 1 {
            throw LayoutCommandError.conflictingArguments(parsed.selectedModes[0], parsed.selectedModes[1])
        }
        if let requestPath = parsed.requestPath {
            return .runRequest(requestPath)
        }
        if parsed.emitsActionDomain {
            return .emitActionDomain
        }
        if parsed.convertsDocument {
            return try makeConversionMode(from: parsed)
        }
        if parsed.inspectsDocument {
            return try makeInspectionMode(from: parsed)
        }
        if parsed.diagnosesConnectivity {
            return try makeConnectivityDiagnosisMode(from: parsed)
        }
        throw LayoutCommandError.missingCommandMode
    }

    private static func makeConversionMode(from parsed: ParsedArguments) throws -> LayoutCommandCLIMode {
        guard let inputPath = parsed.inputPath else {
            throw LayoutCommandError.missingRequiredArgument("--input")
        }
        guard let inputFormat = parsed.inputFormat else {
            throw LayoutCommandError.missingRequiredArgument("--input-format")
        }
        guard let outputPath = parsed.outputPath else {
            throw LayoutCommandError.missingRequiredArgument("--output")
        }
        guard let outputFormat = parsed.outputFormat else {
            throw LayoutCommandError.missingRequiredArgument("--output-format")
        }
        return .convertDocument(LayoutDocumentConversionRequest(
            inputPath: inputPath,
            inputFormat: inputFormat,
            outputPath: outputPath,
            outputFormat: outputFormat,
            technologyPath: parsed.technologyPath,
            resultPath: parsed.resultPath,
            artifactManifestPath: parsed.artifactManifestPath
        ))
    }

    private static func makeInspectionMode(from parsed: ParsedArguments) throws -> LayoutCommandCLIMode {
        guard let inputPath = parsed.inputPath else {
            throw LayoutCommandError.missingRequiredArgument("--input")
        }
        guard let inputFormat = parsed.inputFormat else {
            throw LayoutCommandError.missingRequiredArgument("--input-format")
        }
        return .inspectDocument(LayoutDocumentInspectionRequest(
            inputPath: inputPath,
            inputFormat: inputFormat,
            technologyPath: parsed.technologyPath,
            resultPath: parsed.resultPath,
            artifactManifestPath: parsed.artifactManifestPath
        ))
    }

    private static func makeConnectivityDiagnosisMode(from parsed: ParsedArguments) throws -> LayoutCommandCLIMode {
        guard let inputPath = parsed.inputPath else {
            throw LayoutCommandError.missingRequiredArgument("--input")
        }
        guard let inputFormat = parsed.inputFormat else {
            throw LayoutCommandError.missingRequiredArgument("--input-format")
        }
        return .diagnoseConnectivity(LayoutConnectivityDiagnosisRequest(
            inputPath: inputPath,
            inputFormat: inputFormat,
            technologyPath: parsed.technologyPath
        ))
    }

    private static func parseFormat(_ rawValue: String) throws -> LayoutFileFormat {
        guard let format = LayoutFileFormat(rawValue: rawValue.lowercased()) else {
            throw LayoutCommandError.invalidFormat(rawValue)
        }
        return format
    }
}
