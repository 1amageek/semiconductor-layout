import Foundation

/// Outcome of an antenna jumper insertion pass: how many gates received a
/// jumper and which gates could not be protected, with reasons. The final
/// verdict on whether the mitigation worked belongs to a DRC rerun on the
/// edited document, not to this summary.
public struct AntennaJumperResult: Sendable {
    public var insertedJumpers: Int
    public var failures: [AntennaJumperFailure]

    public init(insertedJumpers: Int, failures: [AntennaJumperFailure]) {
        self.insertedJumpers = insertedJumpers
        self.failures = failures
    }
}
