import Foundation
import LayoutIO

public struct ExternalSignoffRunner: Sendable {
    public var command: ExternalToolCommand

    public init(command: ExternalToolCommand) {
        self.command = command
    }

    public func run(inputLayoutPath: String, outputLogPath: String) throws -> SignoffReport {
        let result = try ExternalToolProcessRunner.run(
            command: command,
            input: inputLayoutPath,
            output: outputLogPath
        )
        return SignoffReport(
            success: result.terminationStatus == 0,
            logPath: outputLogPath,
            rawOutput: result.outputText
        )
    }
}
