import Foundation
import LayoutCommands

@main
struct LayoutCommandCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try LayoutCommandCLIOptions(arguments: arguments)
            let result = try LayoutCommandCLIService().runWithExitStatus(options: options)
            print(result.output)
            if result.exitCode != EXIT_SUCCESS {
                Foundation.exit(result.exitCode)
            }
        } catch {
            if arguments.contains("--json") {
                writeJSONFailure(error)
            } else {
                FileHandle.standardError.write(Data("layout-command failed: \(error.localizedDescription)\n".utf8))
            }
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func writeJSONFailure(_ error: any Error) {
        do {
            let output = try LayoutCommandFailureRenderer().jsonString(for: error)
            FileHandle.standardOutput.write(Data(output.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("layout-command failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
