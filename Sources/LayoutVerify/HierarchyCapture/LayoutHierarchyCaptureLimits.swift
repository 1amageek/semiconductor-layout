/// Caller-owned admission ceilings for synchronous hierarchy capture.
public struct LayoutHierarchyCaptureLimits: Equatable, Sendable {
    public let maximumOccurrences: Int
    public let maximumObjects: Int
    public let maximumGeometryPoints: Int
    public let maximumDepth: Int

    public init(maximumOccurrences: Int, maximumObjects: Int,
                maximumGeometryPoints: Int, maximumDepth: Int) {
        self.maximumOccurrences = maximumOccurrences
        self.maximumObjects = maximumObjects
        self.maximumGeometryPoints = maximumGeometryPoints
        self.maximumDepth = maximumDepth
    }

    /// Admission policy only; these limits do not qualify workload performance.
    public static let `default` = Self(maximumOccurrences: 1_000_000,
                                      maximumObjects: 1_000_000,
                                      maximumGeometryPoints: 8_000_000,
                                      maximumDepth: 64)
}
