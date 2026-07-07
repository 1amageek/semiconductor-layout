import Foundation
import LayoutIO

struct ExternalToolProcessResult: Sendable, Hashable {
    var terminationStatus: Int32
    var outputText: String
}

struct ExternalToolProcessRunner: Sendable {
    static func run(command: ExternalToolCommand, input: String, output: String) throws -> ExternalToolProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments.map {
            $0.replacingOccurrences(of: "{input}", with: input)
                .replacingOccurrences(of: "{output}", with: output)
        }

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.closeFile()
            throw LayoutIOError.conversionFailed("Failed to run command: \(error)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        pipe.fileHandleForReading.closeFile()
        let outputText = String(data: data, encoding: .utf8) ?? ""
        return ExternalToolProcessResult(
            terminationStatus: process.terminationStatus,
            outputText: outputText
        )
    }
}
