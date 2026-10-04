import MaskGeometry

/// Caller-owned host admission policy, independent of workload qualification.
public struct LayoutConductorCaptureLimits: Sendable, Equatable {
    public let hierarchy: LayoutHierarchyCaptureLimits
    public let decomposition: RectilinearDecompositionLimits
    public let maximumTechnologyRecords: Int
    public let maximumFootprints: Int
    public let maximumContactProbes: Int

    public init(hierarchy: LayoutHierarchyCaptureLimits = .default,
                decomposition: RectilinearDecompositionLimits = .default,
                maximumTechnologyRecords: Int = 1_000_000,
                maximumFootprints: Int = 1_000_000, maximumContactProbes: Int = 4_000_000) {
        self.hierarchy = hierarchy
        self.decomposition = decomposition
        self.maximumTechnologyRecords = maximumTechnologyRecords
        self.maximumFootprints = maximumFootprints
        self.maximumContactProbes = maximumContactProbes
    }

    public static let `default` = Self()
}
