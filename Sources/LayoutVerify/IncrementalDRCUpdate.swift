import Foundation
import LayoutCore

/// Result of one `IncrementalDRCSession.apply(_:)` call.
///
/// `result` is the session's full violation snapshot. Checks listed in
/// `staleKinds` were carried from the last full evaluation rather than
/// re-verified against this edit; `commit()` re-verifies them. All other
/// violations are exact for the current geometry.
public struct IncrementalDRCUpdate: Sendable {
    public var result: LayoutDRCResult
    /// Violation kinds whose entries in `result` are carried, not
    /// re-verified. Empty when the snapshot is fully exact.
    public var staleKinds: Set<LayoutViolationKind>
    /// Layers whose geometric checks were recomputed for this edit.
    public var recomputedLayers: [LayoutLayerID]
    /// Number of vias whose enclosure was recomputed for this edit.
    public var recomputedViaCount: Int
    /// Number of nets whose connectivity was recomputed for this edit.
    public var recomputedNetCount: Int
    /// Wall-clock time spent inside `apply(_:)`.
    public var duration: Duration

    public init(
        result: LayoutDRCResult,
        staleKinds: Set<LayoutViolationKind>,
        recomputedLayers: [LayoutLayerID],
        recomputedViaCount: Int,
        recomputedNetCount: Int,
        duration: Duration
    ) {
        self.result = result
        self.staleKinds = staleKinds
        self.recomputedLayers = recomputedLayers
        self.recomputedViaCount = recomputedViaCount
        self.recomputedNetCount = recomputedNetCount
        self.duration = duration
    }
}
