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
    /// Native geometry bands decomposed for edited sources only.
    public var capturedFootprintCount: Int
    /// Footprint/pin candidate inspections for edited sources, including filtered pins.
    public var contactProbeCount: Int
    /// Complete snapshot bands materialized independently of local graph work.
    public var materializedFootprintCount: Int
    /// Cell visits during removal, insertion and local candidate enumeration.
    public var spatialCellVisitCount: Int
    /// Retained index entries; bounded separately from exact contact probes.
    public var storedSpatialEntryCount: Int

    public init(
        analysis: ConnectivityAnalysis,
        recomputedElementCount: Int,
        recomputedComponentCount: Int,
        duration: Duration,
        capturedFootprintCount: Int = 0,
        contactProbeCount: Int = 0,
        materializedFootprintCount: Int = 0,
        spatialCellVisitCount: Int = 0,
        storedSpatialEntryCount: Int = 0
    ) {
        self.analysis = analysis
        self.recomputedElementCount = recomputedElementCount
        self.recomputedComponentCount = recomputedComponentCount
        self.duration = duration
        self.capturedFootprintCount = capturedFootprintCount
        self.contactProbeCount = contactProbeCount
        self.materializedFootprintCount = materializedFootprintCount
        self.spatialCellVisitCount = spatialCellVisitCount
        self.storedSpatialEntryCount = storedSpatialEntryCount
    }
}
