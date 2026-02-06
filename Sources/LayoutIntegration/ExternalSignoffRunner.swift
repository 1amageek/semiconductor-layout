import Foundation
import LayoutIO

public struct ExternalSignoffRunner: Sendable {
    public var command: ExternalToolCommand

    public init(command: ExternalToolCommand) {
        self.command = command
    }

    public func run(inputLayoutPath: String, outputLogPath: String) throws -> SignoffReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments.map {
            $0.replacingOccurrences(of: "{input}", with: inputLayoutPath)
                .replacingOccurrences(of: "{output}", with: outputLogPath)
        }

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            throw LayoutIOError.conversionFailed("Failed to run signoff: \(error)")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: data, encoding: .utf8) ?? ""
        let success = process.terminationStatus == 0
        return SignoffReport(success: success, logPath: outputLogPath, rawOutput: outputText)
    }
}
