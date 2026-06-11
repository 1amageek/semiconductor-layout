import Foundation

/// Result of one `LiveConnectivitySession.apply(_:)` call.
///
/// `analysis` is always exact for the current geometry — connectivity has
/// no deferred tier; the incremental work is bounded by the affected
/// components, whose size the counters report.
public struct LiveConnectivityUpdate: Sendable {
    public var analysis: ConnectivityAnalysis
    /// Number of conductor elements whose component membership was
    /// re-derived for this edit.
    public var recomputedElementCount: Int
    /// Number of connected components rebuilt for this edit.
    public var recomputedComponentCount: Int
    /// Wall-clock time spent inside `apply(_:)`.
    public var duration: Duration

    public init(
        analysis: ConnectivityAnalysis,
        recomputedElementCount: Int,
        recomputedComponentCount: Int,
        duration: Duration
    ) {
        self.analysis = analysis
        self.recomputedElementCount = recomputedElementCount
        self.recomputedComponentCount = recomputedComponentCount
        self.duration = duration
    }
}
