import Foundation
import LayoutCore
import LayoutIntegration
import LayoutIO
import LayoutTech
import Testing

@Suite("External tool process runner", .timeLimit(.minutes(1)))
struct ExternalToolProcessRunnerTests {
    @Test("External signoff drains large shared stdout/stderr output")
    func externalSignoffDrainsLargeOutput() throws {
        let directory = try makeTemporaryDirectory("layout-signoff-large-output")
        defer { removeTemporaryDirectory(directory) }

        let executable = try writeExecutable(
            named: "large-output-signoff",
            in: directory,
            contents: """
            #!/usr/bin/env perl
            for my $i (1..2500) {
                print STDOUT "stdout-$i " . ("x" x 96) . "\\n";
                print STDERR "stderr-$i " . ("y" x 96) . "\\n";
            }
            exit 0;
            """
        )

        let runner = ExternalSignoffRunner(
            command: ExternalToolCommand(
                executable: executable.path,
                arguments: []
            )
        )

        let report = try runner.run(
            inputLayoutPath: directory.appendingPathComponent("input.gds").path,
            outputLogPath: directory.appendingPathComponent("signoff.log").path
        )

        #expect(report.success)
        #expect(report.rawOutput.contains("stdout-2500"))
        #expect(report.rawOutput.contains("stderr-2500"))
        #expect(report.rawOutput.utf8.count > 400_000)
    }

    @Test("Command-line converter drains failure output before checking status")
    func converterDrainsFailureOutput() throws {
        let directory = try makeTemporaryDirectory("layout-converter-large-output")
        defer { removeTemporaryDirectory(directory) }

        let executable = try writeExecutable(
            named: "large-output-converter",
            in: directory,
            contents: """
            #!/usr/bin/env perl
            for my $i (1..2500) {
                print STDOUT "stdout-$i " . ("x" x 96) . "\\n";
                print STDERR "stderr-$i " . ("y" x 96) . "\\n";
            }
            exit 7;
            """
        )
        let converter = CommandLineLayoutConverter(
            configuration: ExternalToolConfiguration(
                documentExport: [
                    .lef: ExternalToolCommand(executable: executable.path, arguments: [])
                ]
            )
        )

        #expect(throws: LayoutIOError.self) {
            try converter.exportDocument(
                LayoutDocument(name: "empty"),
                to: directory.appendingPathComponent("out.lef"),
                format: .lef
            )
        }
    }

    private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory: \(error)")
        }
    }

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
