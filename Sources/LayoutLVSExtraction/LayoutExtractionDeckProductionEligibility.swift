public struct LayoutExtractionDeckProductionEligibility: Sendable, Hashable, Codable {
    public let blockingReasons: [LayoutExtractionDeckProductionBlockReason]

    public init(blockingReasons: [LayoutExtractionDeckProductionBlockReason]) {
        self.blockingReasons = Array(Set(blockingReasons)).sorted()
    }

    public var isEligible: Bool {
        blockingReasons.isEmpty
    }
}
