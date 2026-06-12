import Foundation

public struct LiveLVSUpdate: Sendable {
    public var extraction: DeviceExtractionResult
    public var comparison: NetlistComparison
    public var skippedComparison: Bool
    public var duration: Duration

    public init(
        extraction: DeviceExtractionResult,
        comparison: NetlistComparison,
        skippedComparison: Bool,
        duration: Duration
    ) {
        self.extraction = extraction
        self.comparison = comparison
        self.skippedComparison = skippedComparison
        self.duration = duration
    }

    public var passed: Bool {
        extraction.issues.isEmpty && comparison.passed
    }
}
