import Foundation

public struct SignoffReport: Hashable, Sendable, Codable {
    public var success: Bool
    public var logPath: String
    public var rawOutput: String

    public init(success: Bool, logPath: String, rawOutput: String) {
        self.success = success
        self.logPath = logPath
        self.rawOutput = rawOutput
    }
}
